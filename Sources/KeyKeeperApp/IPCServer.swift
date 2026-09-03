import Foundation
import KeyKeeperCore

protocol SessionControlling: AnyObject, Sendable {
    func status() -> SessionStatus
    func unlock(passphrase: String) throws
    func lock()
    func retrieve(credentialId: String, fieldName: String) throws -> String
}

extension SessionManager: SessionControlling {}

/// Unix domain socket server that receives authorization requests from CLI.
@MainActor
final class IPCServer: ObservableObject {
    @Published var pendingRequest: PendingAuthRequest?
    @Published var pendingServiceRequest: PendingServiceRequest?

    enum StartResult {
        case started(IPCSocketAcquisitionDisposition)
        case anotherInstanceRunning
        case failed(Error)
    }

    private var listener: IPCSocketListener?
    private var listenSource: DispatchSourceRead?
    private var listenCancellationSemaphore: DispatchSemaphore?
    private let queue = DispatchQueue(label: "keykeeper.ipc", qos: .userInitiated)
    private let session: SessionControlling
    private let metaStore: MetaStore
    private let grantStore: GrantStore
    private let serviceGrantStore: ServiceGrantStore

    init(
        session: SessionControlling,
        metaStore: MetaStore = .default,
        grantStore: GrantStore = .default,
        serviceGrantStore: ServiceGrantStore = .default
    ) {
        self.session = session
        self.metaStore = metaStore
        self.grantStore = grantStore
        self.serviceGrantStore = serviceGrantStore
    }

    struct PendingAuthRequest {
        let id: String
        let request: AuthRequest
        let clientFd: Int32
        let requestedAt: Date
        let expiresAt: Date
    }

    struct PendingServiceRequest {
        let id: String
        let request: ValueRequest
        let clientFd: Int32
        let credentialId: String
        let credentialLabel: String
        let fieldNames: [String]
        let callerIdentity: CallerIdentity
        let requestedAt: Date
        let expiresAt: Date

        var summary: PendingServiceRequestSummary {
            PendingServiceRequestSummary(
                id: id,
                credentialId: credentialId,
                credentialLabel: credentialLabel,
                fieldNames: fieldNames,
                callerDisplayName: callerIdentity.displayName,
                subjectFingerprint: callerIdentity.subjectFingerprint,
                requestedAt: requestedAt,
                expiresAt: expiresAt
            )
        }
    }

    @discardableResult
    func start() -> StartResult {
        let path = IPCConstants.socketPath

        let acquisition: IPCSocketAcquisition
        do {
            acquisition = try IPCSocketGuard.acquire(path: path)
        } catch {
            return .failed(error)
        }

        guard case .acquired(let listener, let disposition) = acquisition else {
            return .anotherInstanceRunning
        }

        self.listener = listener
        let fileDescriptor = listener.fileDescriptor
        let cancellationSemaphore = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection(fileDescriptor: fileDescriptor)
        }
        source.setCancelHandler {
            listener.close()
            cancellationSemaphore.signal()
        }
        source.resume()
        listenSource = source
        listenCancellationSemaphore = cancellationSemaphore
        return .started(disposition)
    }

    func stop() {
        guard let listener else { return }

        let source = listenSource
        let cancellationSemaphore = listenCancellationSemaphore
        listenSource = nil
        listenCancellationSemaphore = nil
        self.listener = nil

        if let source {
            source.cancel()
            if cancellationSemaphore?.wait(timeout: .now() + 2) == .timedOut {
                listener.close()
            }
        } else {
            listener.close()
        }
    }

    /// Send response back to the CLI client.
    func respond(to pending: PendingAuthRequest, with response: AuthResponse) {
        expirePendingIfNeeded()
        guard pendingRequest?.id == pending.id else { return }
        pendingRequest = nil
        send(IPCResponse.auth(response), clientFd: pending.clientFd)
    }

    func fulfillServiceRequest(_ pending: PendingServiceRequest, serviceGrant: ServiceGrant) {
        expirePendingIfNeeded()
        guard pendingServiceRequest?.id == pending.id else { return }
        pendingServiceRequest = nil
        let session = self.session
        let grantStore = self.grantStore
        let serviceGrantStore = self.serviceGrantStore
        queue.async {
            Self.readValueAndRespond(
                request: pending.request,
                clientFd: pending.clientFd,
                session: session,
                matchedStrictGrant: nil,
                matchedServiceGrant: serviceGrant,
                grantStore: grantStore,
                serviceGrantStore: serviceGrantStore
            )
        }
    }

    func denyServiceRequest(_ pending: PendingServiceRequest, message: String = "User denied") {
        expirePendingIfNeeded()
        guard pendingServiceRequest?.id == pending.id else { return }
        pendingServiceRequest = nil
        send(
            IPCResponse.value(ValueResponse(
                success: false,
                error: message,
                errorCode: .authorizationDenied
            )),
            clientFd: pending.clientFd
        )
    }

    /// Deny the current pending request.
    func denyPending() {
        guard let pending = pendingRequest else { return }
        respond(to: pending, with: AuthResponse(granted: false, error: "User denied"))
    }

    // MARK: - Private

    private func acceptConnection(fileDescriptor: Int32) {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(fileDescriptor, sockPtr, &clientLen)
            }
        }
        guard clientFd >= 0 else { return }

        // A liveness probe connects and immediately closes. Never let a response to that
        // disconnected client raise SIGPIPE and terminate the healthy server being probed.
        guard Self.prepareAcceptedClient(clientFd) else { return }
        setReadTimeout(fd: clientFd, seconds: IPCConstants.serverReadTimeout)
        let peerPID = peerPID(for: clientFd) ?? 0
        let callerIdentity = CallerIdentityResolver.resolve(peerPID: peerPID)

        // Read envelope
        guard let envelope = IPCMessage.readMessage(fd: clientFd, as: IPCRequest.self) else {
            let response = IPCResponse.value(ValueResponse(
                success: false,
                error: "Invalid request",
                errorCode: .invalidRequest
            ))
            Self.writeAndClose(response, clientFd: clientFd)
            return
        }

        switch envelope {
        case .auth(let request):
            handleAuthRequest(request, clientFd: clientFd, callerIdentity: callerIdentity)
        case .value(let request):
            handleValueRequest(request, clientFd: clientFd, callerIdentity: callerIdentity)
        case .serviceRequests:
            handleServiceRequestsList(clientFd: clientFd)
        case .sessionControl(let request):
            let response = handleSessionControl(request)
            Self.writeAndClose(.sessionControl(response), clientFd: clientFd)
        }
    }

    func handleSessionControl(_ request: SessionControlRequest) -> SessionControlResponse {
        switch request.action {
        case .unlock:
            guard let passphrase = request.passphrase, !passphrase.isEmpty else {
                return invalidSessionControlResponse()
            }
            do {
                try session.unlock(passphrase: passphrase)
                return response(for: session.status())
            } catch {
                return SessionControlResponse(
                    success: false,
                    error: "Unable to unlock session",
                    errorCode: .unlockFailed
                )
            }
        case .lock:
            guard request.passphrase == nil else {
                return invalidSessionControlResponse()
            }
            session.lock()
            return response(for: session.status())
        case .status:
            guard request.passphrase == nil else {
                return invalidSessionControlResponse()
            }
            return response(for: session.status())
        }
    }

    private func response(for status: SessionStatus) -> SessionControlResponse {
        switch status {
        case .locked:
            return SessionControlResponse(success: true, state: .locked)
        case .unlocked(expiresAt: nil):
            return SessionControlResponse(success: true, state: .unlockedManual)
        case .unlocked(expiresAt: let expiration?):
            return SessionControlResponse(
                success: true,
                state: .unlockedUntil,
                expiresAt: expiration
            )
        }
    }

    private func invalidSessionControlResponse() -> SessionControlResponse {
        SessionControlResponse(
            success: false,
            error: "Invalid session control request",
            errorCode: .invalidRequest
        )
    }

    nonisolated static func prepareAcceptedClient(_ clientFd: Int32) -> Bool {
        guard fcntl(clientFd, F_SETNOSIGPIPE, 1) != -1 else {
            close(clientFd)
            return false
        }
        return true
    }

    private func handleAuthRequest(_ request: AuthRequest,
                                   clientFd: Int32,
                                   callerIdentity: CallerIdentity) {
        var enrichedRequest = request
        enrichedRequest.pid = callerIdentity.peerPID
        enrichedRequest.callerIdentity = callerIdentity

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.expirePendingIfNeeded()

            // If there's already a pending request, deny the new one
            if self.pendingRequest != nil || self.pendingServiceRequest != nil {
                self.send(
                    IPCResponse.auth(AuthResponse(
                        granted: false,
                        error: "Another authorization is in progress"
                    )),
                    clientFd: clientFd
                )
                return
            }

            let now = Date()
            let pending = PendingAuthRequest(
                id: UUID().uuidString,
                request: enrichedRequest,
                clientFd: clientFd,
                requestedAt: now,
                expiresAt: now.addingTimeInterval(IPCConstants.authTimeout)
            )
            self.pendingRequest = pending
            self.scheduleExpirationCheck()
        }
    }

    func handleValueRequest(_ request: ValueRequest,
                            clientFd: Int32,
                            callerIdentity: CallerIdentity) {
        // Load credential metadata to check security level
        guard let meta = try? metaStore.load(),
              let cred = meta.credentials[request.credentialId],
              let field = cred.fields[request.fieldName],
              field.secret else {
            let resp = IPCResponse.value(ValueResponse(
                success: false,
                error: "Credential or field not found",
                errorCode: .notFound
            ))
            Self.writeAndClose(resp, clientFd: clientFd)
            return
        }

        // A locked value request must not inspect grants, record service audit
        // events, or enter either authorization queue.
        guard case .unlocked = session.status() else {
            let resp = IPCResponse.value(ValueResponse(
                success: false,
                error: "Credential vault is locked",
                errorCode: .keychainError,
                storageErrorCode: .vaultLocked
            ))
            Self.writeAndClose(resp, clientFd: clientFd)
            return
        }

        // For strict credentials, verify the existing session grant path.
        var matchedStrictGrant: Grant?
        if cred.security == .strict {
            guard let grant = try? GrantAuthorizationPolicy.validGrantForValueAccess(
                credentialId: request.credentialId,
                sessionId: request.sessionId,
                grantStore: grantStore
            ) else {
                let resp = IPCResponse.value(ValueResponse(
                    success: false,
                    error: "No valid grant",
                    errorCode: .noAuthorization
                ))
                Self.writeAndClose(resp, clientFd: clientFd)
                return
            }
            matchedStrictGrant = grant
        }

        do {
            let serviceDecision = try ServiceAuthorizationPolicy.decisionForValueAccess(
                credential: cred,
                credentialId: request.credentialId,
                fieldName: request.fieldName,
                caller: callerIdentity,
                serviceGrantStore: serviceGrantStore
            )

            switch serviceDecision {
            case .allowed(let serviceGrant):
                Self.readValueAndRespond(
                    request: request,
                    clientFd: clientFd,
                    session: session,
                    matchedStrictGrant: matchedStrictGrant,
                    matchedServiceGrant: serviceGrant,
                    grantStore: grantStore,
                    serviceGrantStore: serviceGrantStore
                )

            case .promptRequired:
                enqueueServiceRequest(
                    request,
                    credential: cred,
                    clientFd: clientFd,
                    callerIdentity: callerIdentity
                )
            }
        } catch {
            let resp = IPCResponse.value(ValueResponse(
                success: false,
                error: error.localizedDescription,
                errorCode: .noAuthorization
            ))
            Self.writeAndClose(resp, clientFd: clientFd)
        }
    }

    private func enqueueServiceRequest(_ request: ValueRequest,
                                       credential: Credential,
                                       clientFd: Int32,
                                       callerIdentity: CallerIdentity) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.expirePendingIfNeeded()

            guard self.pendingRequest == nil, self.pendingServiceRequest == nil else {
                self.send(
                    IPCResponse.value(ValueResponse(
                        success: false,
                        error: "Another authorization is in progress",
                        errorCode: .noAuthorization
                    )),
                    clientFd: clientFd
                )
                return
            }

            let requestedFields = self.validRequestedFields(
                request.requestedFieldNames,
                currentFieldName: request.fieldName,
                credential: credential
            )
            let now = Date()
            let pending = PendingServiceRequest(
                id: UUID().uuidString,
                request: request,
                clientFd: clientFd,
                credentialId: request.credentialId,
                credentialLabel: credential.label,
                fieldNames: requestedFields,
                callerIdentity: callerIdentity,
                requestedAt: now,
                expiresAt: now.addingTimeInterval(IPCConstants.authTimeout)
            )
            self.pendingServiceRequest = pending
            self.scheduleExpirationCheck()
        }
    }

    private func handleServiceRequestsList(clientFd: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.expirePendingIfNeeded()
            let summaries = self.pendingServiceRequest.map { [$0.summary] } ?? []
            self.send(
                IPCResponse.serviceRequests(ServiceRequestsListResponse(requests: summaries)),
                clientFd: clientFd
            )
        }
    }

    private nonisolated static func readValueAndRespond(request: ValueRequest,
                                                        clientFd: Int32,
                                                        session: SessionControlling,
                                                        matchedStrictGrant: Grant?,
                                                        matchedServiceGrant: ServiceGrant?,
                                                        grantStore: GrantStore,
                                                        serviceGrantStore: ServiceGrantStore) {
        let response = retrieveSessionValue(
            session: session,
            credentialId: request.credentialId,
            fieldName: request.fieldName
        )

        if response.success {
            try? GrantAuthorizationPolicy.consumeOnceGrantAfterSuccessfulValueIfNeeded(
                matchedStrictGrant,
                grantStore: grantStore
            )
            if let matchedServiceGrant {
                try? serviceGrantStore.noteSuccessfulUse(
                    grantId: matchedServiceGrant.id,
                    fieldName: request.fieldName
                )
            }
        }

        Self.writeAndClose(IPCResponse.value(response), clientFd: clientFd)
    }

    private nonisolated static func retrieveSessionValue(
        session: SessionControlling,
        credentialId: String,
        fieldName: String
    ) -> ValueResponse {
        do {
            return ValueResponse(
                success: true,
                value: try session.retrieve(
                    credentialId: credentialId,
                    fieldName: fieldName
                )
            )
        } catch SessionManagerError.locked {
            return ValueResponse(
                success: false,
                error: "Credential vault is locked",
                errorCode: .keychainError,
                storageErrorCode: .vaultLocked
            )
        } catch KeychainError.notFound {
            return ValueResponse(
                success: false,
                error: "Credential value not found",
                errorCode: .notFound,
                storageErrorCode: .readFailed
            )
        } catch {
            return ValueResponse(
                success: false,
                error: "Credential vault read failed",
                errorCode: .keychainError,
                storageErrorCode: .readFailed
            )
        }
    }

    private func validRequestedFields(_ requestedFieldNames: [String],
                                      currentFieldName: String,
                                      credential: Credential) -> [String] {
        var fields = Set(requestedFieldNames.filter { fieldName in
            credential.fields[fieldName]?.secret == true
        })
        fields.insert(currentFieldName)
        return fields.sorted()
    }

    private func expirePendingIfNeeded(now: Date = Date()) {
        if let pending = pendingRequest, now >= pending.expiresAt {
            pendingRequest = nil
            send(
                IPCResponse.auth(AuthResponse(granted: false, error: "Authorization request expired")),
                clientFd: pending.clientFd
            )
        }

        if let pending = pendingServiceRequest, now >= pending.expiresAt {
            pendingServiceRequest = nil
            send(
                IPCResponse.value(ValueResponse(
                    success: false,
                    error: "Service authorization request expired",
                    errorCode: .pendingExpired
                )),
                clientFd: pending.clientFd
            )
        }
    }

    private func scheduleExpirationCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + IPCConstants.authTimeout) { [weak self] in
            self?.expirePendingIfNeeded()
        }
    }

    private func send(_ response: IPCResponse, clientFd: Int32) {
        queue.async {
            Self.writeAndClose(response, clientFd: clientFd)
        }
    }

    private func setReadTimeout(fd: Int32, seconds: TimeInterval) {
        var timeout = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func peerPID(for fd: Int32) -> Int32? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length)
        guard result == 0 else { return nil }
        return Int32(pid)
    }

    private nonisolated static func writeAndClose(_ response: IPCResponse, clientFd: Int32) {
        try? IPCMessage.writeMessage(fd: clientFd, message: response)
        close(clientFd)
    }
}
