import Foundation
import CryptoKit
import KeyKeeperCore

protocol SessionControlling: AnyObject, Sendable {
    var isVaultInitialized: Bool { get }
    func status() -> SessionStatus
    func unlock(passphrase: String) throws
    func lock()
    func retrieve(credentialId: String, fieldName: String) throws -> String
}

/// Keychain-backed storage has no lock: logging into the Mac IS the unlock
/// (decision 2026-09-03, 方案-20260903-去passphrase化). The protocol keeps its
/// unlock/lock surface only for wire compatibility with older CLIs.
extension KeychainCredentialService: SessionControlling {
    var isVaultInitialized: Bool { true }
    func unlock(passphrase: String) throws {}
    func lock() {}
}

/// Unix domain socket server that receives authorization requests from CLI.
@MainActor
final class IPCServer: ObservableObject {
    @Published var pendingRequest: PendingAuthRequest?
    @Published var pendingServiceRequest: PendingServiceRequest?
    /// Requests waiting behind the one currently shown. They used to be denied outright,
    /// which made concurrent cron jobs fail with "denied" although nobody had denied them.
    @Published private(set) var waitingCount = 0
    /// Metadata-only projection for the menu panel. The pasted candidate remains inside the
    /// bridge and its dedicated Keychain journal.
    @Published private(set) var browserImportProposal: BrowserImportProposalSnapshot?

    static let maximumWaiting = 16
    static let busyMessage =
        "KeyKeeper already has \(maximumWaiting) authorization requests waiting. " +
        "Approve or deny them in the KeyKeeper window, then retry."

    private enum WaitingAuthorization {
        case auth(PendingAuthRequest)
        case service(PendingServiceRequest)

        var clientFd: Int32 {
            switch self {
            case .auth(let pending): return pending.clientFd
            case .service(let pending): return pending.clientFd
            }
        }
    }

    private var waiting: [WaitingAuthorization] = []

    enum StartResult {
        case started(IPCSocketAcquisitionDisposition)
        case anotherInstanceRunning
        case failed(Error)
    }

    private var listener: IPCSocketListener?
    private var listenSource: DispatchSourceRead?
    private var listenCancellationSemaphore: DispatchSemaphore?
    private let queue: DispatchQueue
    private let session: SessionControlling
    private let metaStore: MetaStore
    private let accessGate: VaultAccessGate?
    private let approvals: ApprovalStore
    private let clipboardSaveController: ClipboardSaveController?
    private let envImportController: EnvImportController?
    private let browserSessionController: BrowserSessionController?
    private let browserImportProposalStore: BrowserImportProposalStore?
    private var browserImportStoreAvailable = true
    private var browserImportBridge: BrowserImportBridge?
    private var browserImportBridges: [String: BrowserImportBridge] = [:]

    @MainActor func importFile(_ request: FileImportRequest, callerName: String = "KeyKeeper",
                    isConnected: @escaping () -> Bool = { true },
                    completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard let controller = clipboardSaveController else {
            completion(.init(success: false, errorCode: .storageUnavailable)); return
        }
        guard pendingRequest == nil, pendingServiceRequest == nil, !controller.isPending, browserSessionController?.isPending != true, envImportController?.isPending != true else {
            completion(.init(success: false, errorCode: .busy)); return
        }
        do {
            try request.validate()
            let format: CredentialFileFormat
            if let provider = request.target.provider {
                guard let template = ProviderCatalog.find(provider),
                      let declared = template.field(named: request.target.fieldName),
                      declared.kind == .secretFile, let declaredFormat = declared.fileFormat else {
                    throw ClipboardSaveError.wrongFieldType
                }
                format = declaredFormat
            } else {
                format = .serviceAccountJSON
            }
            let source = try CredentialFileSource(filePath: request.filePath, format: format)
            controller.receive(request.target, callerName: callerName, isConnected: isConnected,
                               source: source, completion: completion)
        } catch { completion(.init(success: false, errorCode: error as? ClipboardSaveError ?? .invalidFile)) }
    }

    @MainActor func importEnv(_ request: EnvImportRequest, callerName: String,
                    isConnected: @escaping () -> Bool,
                    completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard let controller = envImportController else {
            completion(.init(success: false, errorCode: .storageUnavailable)); return
        }
        guard pendingRequest == nil, pendingServiceRequest == nil, clipboardSaveController?.isPending != true,
              browserSessionController?.isPending != true, !controller.isPending else {
            completion(.init(success: false, errorCode: .busy)); return
        }
        controller.receive(request, callerName: callerName, isConnected: isConnected, completion: completion)
    }

    @MainActor func importSource(_ request: SourceImportRequest, callerName: String,
                    isConnected: @escaping () -> Bool,
                    completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard let controller = clipboardSaveController else {
            completion(.init(success: false, errorCode: .storageUnavailable)); return
        }
        guard pendingRequest == nil, pendingServiceRequest == nil, !controller.isPending, browserSessionController?.isPending != true, envImportController?.isPending != true else {
            completion(.init(success: false, errorCode: .busy)); return
        }
        do {
            try request.validate()
            let source = try CredentialFileSource(filePath: request.filePath, pythonSymbol: request.pythonSymbol)
            controller.receive(request.target, callerName: callerName, isConnected: isConnected,
                               source: source, completion: completion)
        } catch { completion(.init(success: false, errorCode: error as? ClipboardSaveError ?? .invalidSource)) }
    }

    init(
        session: SessionControlling,
        metaStore: MetaStore = .default,
        approvals: ApprovalStore,
        clipboardSaveController: ClipboardSaveController? = nil,
        envImportController: EnvImportController? = nil,
        browserSessionController: BrowserSessionController? = nil,
        browserImportProposalStore: BrowserImportProposalStore? = nil,
        accessGate: VaultAccessGate? = nil,
        workerQueue: DispatchQueue? = nil
    ) {
        self.session = session
        self.metaStore = metaStore
        self.accessGate = accessGate
        self.queue = workerQueue ?? DispatchQueue(label: "keykeeper.ipc", qos: .userInitiated)
        self.approvals = approvals
        self.clipboardSaveController = clipboardSaveController
        self.envImportController = envImportController
        self.browserSessionController = browserSessionController
        self.browserImportProposalStore = browserImportProposalStore
        browserSessionController?.otherApprovalPending = { [weak self] in
            guard let self else { return true }
            return self.pendingRequest != nil || self.pendingServiceRequest != nil || self.clipboardSaveController?.isPending == true || self.envImportController?.isPending == true
        }
    }

    @MainActor func handleClipboardSave(_ request: ClipboardSaveRequest, clientFd: Int32,
                                        peerPID: pid_t, callerName: String) {
        guard let controller = clipboardSaveController else {
            send(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
            return
        }
        guard pendingRequest == nil, pendingServiceRequest == nil, browserSessionController?.isPending != true, envImportController?.isPending != true else {
            send(.clipboardSave(.init(success: false, errorCode: .busy)), clientFd: clientFd)
            return
        }
        controller.receive(request, callerName: callerName,
            isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
            completion: { response in self.send(.clipboardSave(response), clientFd: clientFd) })
    }

    struct PendingAuthRequest {
        let id: String
        let request: AuthRequest
        let clientFd: Int32
        let requestedAt: Date
        let metadataFingerprint: Data
        let vaultEpoch: UInt64?
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
        let metadataFingerprint: Data
        let vaultEpoch: UInt64?
        var summary: PendingServiceRequestSummary {
            PendingServiceRequestSummary(
                id: id,
                credentialId: credentialId,
                credentialLabel: credentialLabel,
                fieldNames: fieldNames,
                callerDisplayName: callerIdentity.displayName,
                subjectFingerprint: callerIdentity.subjectFingerprint,
                requestedAt: requestedAt,
                // Keep the older CLI's non-optional wire field. The live request itself has
                // no clock deadline: only the calling process can end it.
                expiresAt: .distantFuture
            )
        }
    }

    private(set) var vaultRecoveryFailed = false

    @discardableResult
    func start(socketPath: String = IPCConstants.socketPath,
               recoverVault: () throws -> Void = {}) -> StartResult {
        let path = socketPath

        let acquisition: IPCSocketAcquisition
        do {
            acquisition = try IPCSocketGuard.acquire(path: path)
        } catch {
            return .failed(error)
        }

        guard case .acquired(let listener, let disposition) = acquisition else {
            return .anotherInstanceRunning
        }

        // Only the owner of the endpoint may recover. No accepted request or import
        // restoration runs while the local transaction is being checked.
        do { try recoverVault(); vaultRecoveryFailed = false }
        catch { vaultRecoveryFailed = true }
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
        if !vaultRecoveryFailed { restoreBrowserImportProposal() }
        return .started(disposition)
    }

    func stop() {
        if browserImportBridge?.suspendForTermination() != true { clipboardSaveController?.cancel() }
        envImportController?.cancel()
        browserSessionController?.stopAll()
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
        refreshPending()
        guard pendingRequest?.id == pending.id else { return }
        pendingRequest = nil
        send(IPCResponse.auth(response), clientFd: pending.clientFd)
        promoteNextWaiting()
    }

    func isLive(_ pending: PendingAuthRequest) -> Bool {
        refreshPending()
        return pendingRequest?.id == pending.id && Self.isClientConnected(pending.clientFd)
    }

    func isLive(_ pending: PendingServiceRequest) -> Bool {
        refreshPending()
        return pendingServiceRequest?.id == pending.id && Self.isClientConnected(pending.clientFd)
    }

    /// Approval is issued here, beside metadata admission, rather than by an unchecked UI
    /// callback. A waiting dialog is not evidence that the store is still readable or unchanged.
    func approveAuthRequest(_ pending: PendingAuthRequest, choice: AuthorizationView.DurationChoice) throws {
        try withVaultAccess(expectedEpoch: pending.vaultEpoch, requireEpoch: true) {
            guard isLive(pending) else { throw ApprovalIssuanceError.requestEnded }
            _ = try Self.checkedCredential(metaStore, id: pending.request.credentialId,
                                           fingerprint: pending.metadataFingerprint)
            let request = pending.request
            let duration = try DurationResolution.issued(choice, sessionId: request.sessionId, identity: request.callerIdentity)
            let approval = Approval(
                subject: .init(fingerprint: request.callerIdentity?.subject.fingerprint ?? "",
                               displayName: request.callerIdentity?.displayName ?? L("Unknown Caller")),
                target: .credential(id: request.credentialId, fields: nil), duration: duration,
                onceFieldsRemaining: duration == .once ? request.fieldNames : nil,
                reason: request.statedReason?.text, command: request.commandSummary)
            try approvals.add(approval)
            respond(to: pending, with: .init(granted: true, grantId: approval.id))
        }
    }

    func approveServiceRequest(_ pending: PendingServiceRequest, choice: AuthorizationView.DurationChoice) throws {
        try withVaultAccess(expectedEpoch: pending.vaultEpoch, requireEpoch: true) {
            guard isLive(pending) else { throw ApprovalIssuanceError.requestEnded }
            _ = try Self.checkedCredential(metaStore, id: pending.credentialId, fingerprint: pending.metadataFingerprint)
            let duration = try DurationResolution.issued(choice, sessionId: pending.request.sessionId, identity: pending.callerIdentity)
            let approval = Approval(
                subject: .init(fingerprint: pending.callerIdentity.subjectFingerprint,
                               displayName: pending.callerIdentity.displayName),
                target: .credential(id: pending.credentialId, fields: pending.fieldNames), duration: duration,
                onceFieldsRemaining: duration == .once ? pending.fieldNames : nil,
                reason: pending.request.statedReason?.text, command: pending.request.commandSummary)
            do {
                try approvals.add(approval)
                fulfillServiceRequest(pending, approval: approval)
            } catch ApprovalIssuanceError.unidentifiedCaller {
                fulfillServiceRequest(pending, approval: nil)
            }
        }
    }

    func approveStandingRequest(_ request: StandingApprovalRequest, choice: AuthorizationView.DurationChoice,
                                expectedEpoch: UInt64? = nil) throws {
        try withVaultAccess(expectedEpoch: expectedEpoch, requireEpoch: true) {
            let credential = try Self.checkedCredential(metaStore, id: request.credentialId)
            let secretFields = Set(credential.fields.filter { $0.value.secret }.keys)
            guard credential.label == request.credentialLabel, secretFields == Set(request.fieldNames) else {
                throw AuthorizationMetadataError.changed
            }
            let duration = try DurationResolution.issued(choice, sessionId: nil, identity: request.callerIdentity)
            try approvals.add(.init(subject: .init(fingerprint: request.callerIdentity.subjectFingerprint,
                                                   displayName: request.callerIdentity.displayName),
                target: .credential(id: request.credentialId, fields: nil), duration: duration,
                onceFieldsRemaining: duration == .once ? request.fieldNames : nil,
                reason: request.reason, command: request.command))
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        }
    }

    nonisolated private static func metadataFingerprint(_ credential: Credential) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Data(SHA256.hash(data: try encoder.encode(credential)))
    }

    nonisolated private static func checkedCredential(_ store: MetaStore, id: String,
                                                      fingerprint: Data? = nil) throws -> Credential {
        guard let credential = try store.loadForUse().credentials[id] else { throw AuthorizationMetadataError.changed }
        if let fingerprint, try metadataFingerprint(credential) != fingerprint { throw AuthorizationMetadataError.changed }
        return credential
    }

    /// `approval` is what the person's answer was stored as — nil when it could not be stored
    /// (an unidentified caller gets this one answer and nothing remembered).
    func fulfillServiceRequest(_ pending: PendingServiceRequest, approval: Approval?) {
        refreshPending()
        guard pendingServiceRequest?.id == pending.id else { return }
        pendingServiceRequest = nil
        defer { promoteNextWaiting() }
        let session = self.session
        let approvals = self.approvals
        let metaStore = self.metaStore
        let accessGate = self.accessGate
        queue.async {
            do {
                let fulfill = {
                    _ = try Self.checkedCredential(metaStore, id: pending.credentialId,
                                                   fingerprint: pending.metadataFingerprint)
                    // The grant may have been revoked or spent after the prompt closed but
                    // before this worker ran. Only the captured, still-valid grant can pay.
                    if let approval {
                        let current = try approvals.valid(credentialId: pending.credentialId,
                            field: pending.request.fieldName, fingerprint: pending.callerIdentity.subjectFingerprint,
                            terminalSession: pending.request.sessionId, approvalID: approval.id)
                        guard current?.id == approval.id else { throw ApprovalIssuanceError.requestEnded }
                    }
                    Self.readValueAndRespond(request: pending.request, clientFd: pending.clientFd,
                                             session: session, matched: approval, approvals: approvals)
                }
                if let accessGate {
                    guard let epoch = pending.vaultEpoch else { throw VaultAccessError.staleEpoch }
                    try accessGate.withAccess(expectedEpoch: epoch, fulfill)
                } else {
                    try fulfill()
                }
            } catch {
                Self.writeAndClose(.value(.init(success: false, error: error.localizedDescription,
                    errorCode: .keychainError, storageErrorCode: .readFailed)), clientFd: pending.clientFd)
            }
        }
    }

    func denyServiceRequest(_ pending: PendingServiceRequest, message: String = "User denied") {
        refreshPending()
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
        promoteNextWaiting()
    }

    /// Deny the current pending request.
    func denyPending() {
        guard let pending = pendingRequest else { return }
        respond(to: pending, with: AuthResponse(granted: false, error: "User denied"))
    }

    func reopenBrowserImportProposal(id: String) {
        guard browserImportProposal?.id == id else { return }
        browserImportBridges[id]?.reopen()
    }

    func cancelBrowserImportProposal(id: String) {
        guard browserImportProposal?.id == id else { return }
        browserImportBridges[id]?.cancel()
    }

    /// Called only after this process owns the IPC socket, so a duplicate launch never reads or
    /// mutates the proposal Keychain item. At most one nonterminal record is admitted by the store.
    func restoreBrowserImportProposal() {
        guard let store = browserImportProposalStore else { return }
        do {
            // start() calls this before LaunchMaintenance. Do not resume or rewrite an
            // import journal while the credential metadata cannot be authenticated.
            _ = try metaStore.loadForUse()
            let records = try store.records()
            guard let record = records.first(where: { !$0.snapshot.state.isTerminal }) else { return }
            guard let controller = clipboardSaveController, !controller.isPending else {
                browserImportStoreAvailable = false
                return
            }
            let bridge = makeBrowserImportBridge(controller: controller, store: store)
            browserImportBridge = bridge
            browserImportBridges[record.snapshot.id] = bridge
            _ = bridge.recover(record)
        } catch {
            // Other KeyKeeper features remain usable, but browser import must not create a second
            // journal over an unreadable or missing first one.
            browserImportStoreAvailable = false
        }
    }

    private func makeBrowserImportBridge(controller: ClipboardSaveController,
                                         store: BrowserImportProposalStore) -> BrowserImportBridge {
        BrowserImportBridge(controller: controller, proposalStore: store,
            onSnapshotChange: { [weak self] snapshot in
                self?.browserImportProposal = snapshot.state.isTerminal ? nil : snapshot
            })
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
        // Identity is bound to the connection, not to whatever the pid becomes later. A caller
        // whose token cannot be read is resolved the old way and comes back unverified, which
        // matches no approval — it can still be allowed, but only by a person, every time.
        let callerIdentity: CallerIdentity
        if let token = peerAuditToken(for: clientFd) {
            callerIdentity = CallerIdentityResolver.resolve(auditToken: token)
        } else {
            let pid = peerPID(for: clientFd) ?? 0
            let resolved = CallerIdentityResolver.resolve(peerPID: pid)
            callerIdentity = CallerIdentity(
                peerPID: resolved.peerPID, executablePath: resolved.executablePath,
                bundleIdentifier: resolved.bundleIdentifier, teamIdentifier: resolved.teamIdentifier,
                signingIdentifier: resolved.signingIdentifier, parentChain: resolved.parentChain,
                subject: CallerSubject(kind: resolved.subject.kind,
                                       fingerprint: CallerSubject.unverifiedPrefix + "no-audit-token",
                                       displayName: resolved.subject.displayName,
                                       detail: resolved.subject.detail))
        }
        let peerPID = callerIdentity.peerPID

        // Read envelope
        // A request must arrive within the deadline; a byte-at-a-time sender cannot hold this
        // serial queue. (Only here: clients waiting on a person must not inherit it.)
        guard let envelope = IPCMessage.readMessage(fd: clientFd, as: IPCRequest.self,
                                                    deadline: IPCMessage.messageDeadline) else {
            let response = IPCResponse.value(ValueResponse(
                success: false,
                error: "Invalid request",
                errorCode: .invalidRequest
            ))
            Self.writeAndClose(response, clientFd: clientFd)
            return
        }

        switch envelope {
        case .browserSession(let request):
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.browserSessionController else {
                    Self.writeAndClose(.browserSession(.init(success: false, errorCode: .unavailable)), clientFd: clientFd); return
                }
                controller.receive(request, caller: callerIdentity.displayName,
                                   fingerprint: callerIdentity.subject.fingerprint,
                    isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
                    completion: { response in self.send(.browserSession(response), clientFd: clientFd) })
            }
        case .sourceImport(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                self.importSource(request, callerName: callerIdentity.displayName,
                    isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
                    completion: { response in self.send(.clipboardSave(response), clientFd: clientFd) })
            }
        case .envImport(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                self.importEnv(request, callerName: callerIdentity.displayName,
                    isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
                    completion: { response in self.send(.clipboardSave(response), clientFd: clientFd) })
            }
        case .fileImport(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                self.importFile(request, callerName: callerIdentity.displayName,
                    isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
                    completion: { response in self.send(.clipboardSave(response), clientFd: clientFd) })
            }
        case .browserImport(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self, let controller = self.clipboardSaveController,
                      let proposalStore = self.browserImportProposalStore,
                      self.browserImportStoreAvailable else {
                    Self.writeAndClose(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                do {
                    guard try proposalStore.records().allSatisfy({ $0.snapshot.state.isTerminal }) else {
                        self.send(.clipboardSave(.init(success: false, errorCode: .busy)), clientFd: clientFd)
                        return
                    }
                } catch {
                    self.browserImportStoreAvailable = false
                    self.send(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                guard self.pendingRequest == nil, self.pendingServiceRequest == nil, !controller.isPending, self.browserSessionController?.isPending != true, self.envImportController?.isPending != true, envImportController?.isPending != true else {
                    self.send(.clipboardSave(.init(success: false, errorCode: .busy)), clientFd: clientFd)
                    return
                }
                let bridge = self.makeBrowserImportBridge(controller: controller, store: proposalStore)
                self.browserImportBridge = bridge
                bridge.start(request, callerName: callerIdentity.displayName,
                    isConnected: { peerPID > 0 && Self.isClientConnected(clientFd) },
                    ready: { url in
                        self.browserImportBridges[bridge.snapshot.id] = bridge
                        if self.browserImportBridges.count > 16,
                           let old = self.browserImportBridges.first(where: { $0.key != bridge.snapshot.id && $0.value.snapshot.state.isTerminal }) {
                            old.value.shutdown(); self.browserImportBridges.removeValue(forKey: old.key)
                        }
                        self.queue.async {
                            do { try IPCMessage.writeMessage(fd: clientFd, message: IPCResponse.browserImportReady(url), deadline: IPCMessage.messageDeadline) }
                            catch { DispatchQueue.main.async { bridge.cancel() } }
                        }
                    }, completion: { response in
                        if self.browserImportBridge === bridge { self.browserImportBridge = nil }
                        self.send(.clipboardSave(response), clientFd: clientFd)
                    })
            }
        case .browserImportProposal(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.browserImportProposal(.init(error: .notFound)), clientFd: clientFd)
                    return
                }
                do {
                    try request.validate()
                    if let bridge = self.browserImportBridges[request.id] {
                        if request.action == .open {
                            guard !bridge.snapshot.state.isTerminal else {
                                self.send(.browserImportProposal(.init(error: .noLongerOpen)), clientFd: clientFd)
                                return
                            }
                            bridge.reopen()
                        }
                        self.send(.browserImportProposal(.init(proposal: bridge.snapshot)), clientFd: clientFd)
                        return
                    }
                    guard self.browserImportStoreAvailable,
                          let record = try self.browserImportProposalStore?.record(id: request.id) else {
                        self.send(.browserImportProposal(.init(error: .notFound)), clientFd: clientFd)
                        return
                    }
                    if request.action == .open {
                        guard !record.snapshot.state.isTerminal else {
                            self.send(.browserImportProposal(.init(error: .noLongerOpen)), clientFd: clientFd)
                            return
                        }
                        guard let controller = self.clipboardSaveController,
                              !controller.isPending,
                              let store = self.browserImportProposalStore else {
                            self.send(.browserImportProposal(.init(proposal: record.snapshot)), clientFd: clientFd)
                            return
                        }
                        let bridge = self.makeBrowserImportBridge(controller: controller, store: store)
                        self.browserImportBridge = bridge
                        self.browserImportBridges[request.id] = bridge
                        _ = bridge.recover(record)
                        bridge.reopen()
                        self.send(.browserImportProposal(.init(proposal: bridge.snapshot)), clientFd: clientFd)
                        return
                    }
                    self.send(.browserImportProposal(.init(proposal: record.snapshot)), clientFd: clientFd)
                } catch {
                    if error is BrowserImportProposalStoreError {
                        self.browserImportStoreAvailable = false
                        self.send(.browserImportProposal(.init(error: .notFound)), clientFd: clientFd)
                    } else {
                        self.send(.browserImportProposal(.init(error: .invalidID)), clientFd: clientFd)
                    }
                }
            }
        case .clipboardSave(let request):
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.clipboardSave(.init(success: false, errorCode: .storageUnavailable)), clientFd: clientFd)
                    return
                }
                self.handleClipboardSave(request, clientFd: clientFd, peerPID: peerPID,
                                         callerName: callerIdentity.displayName)
            }
        case .auth(let request):
            handleAuthRequest(request, clientFd: clientFd, callerIdentity: callerIdentity)
        case .value(let request):
            handleValueRequest(request, clientFd: clientFd, callerIdentity: callerIdentity)
        case .serviceRequests:
            handleServiceRequestsList(clientFd: clientFd)
        case .approvalRevoke(let request):
            let response: ApprovalRevokeResponse
            do {
                response = try approvals.revoke(id: request.id)
                    ? .init(success: true)
                    : .init(success: false, error: "No approval has that ID. Run keykeeper grants list to see the IDs.")
            } catch {
                response = .init(success: false, error: error.localizedDescription)
            }
            send(.approvalRevoke(response), clientFd: clientFd)
        case .approvalsList(let request):
            let response: ApprovalsListResponse
            do {
                let all = try request.credentialId.map { try approvals.approvals(forCredential: $0) } ?? approvals.all()
                response = ApprovalsListResponse(mode: try approvals.mode(), approvals: all.map { $0.redactedForCaller() })
            } catch {
                response = ApprovalsListResponse(mode: .enforced, approvals: [])
            }
            send(.approvalsList(response), clientFd: clientFd)
        case .metadataIntegrity:
            let verdict = (try? metaStore.loadVerified().verdict) ?? .tampered
            send(.metadataIntegrity(MetadataIntegrityResponse(verdict)), clientFd: clientFd)
        case .sessionControl(let request):
            let response = handleSessionControl(request)
            Self.writeAndClose(.sessionControl(response), clientFd: clientFd)
        case .metadataEdit(let request):
            // On the main queue, so it never interleaves with an edit made in the window.
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    Self.writeAndClose(.metadataEdit(.init(success: false, error: "KeyKeeper is shutting down.")), clientFd: clientFd)
                    return
                }
                let response = self.handleMetadataEdit(request, callerName: callerIdentity.displayName)
                self.send(.metadataEdit(response), clientFd: clientFd)
            }
        }
    }

    /// Names and notes only — never values or security — so no prompt: the change is applied,
    /// written to the change log, and shown in the menu bar and access log afterwards.
    func handleMetadataEdit(_ request: MetadataEditRequest, callerName: String,
                            changeLog: MetadataChangeLog = .default) -> MetadataEditResponse {
        guard let manager = session as? any CredentialSessionManaging else {
            return .init(success: false, error: "Storage cannot be safely updated.")
        }
        let editor = MetadataEditor(session: manager, metaStore: metaStore, approvals: approvals)
        do {
            let result = try editor.apply(request.edit, groupId: request.groupId, caller: callerName)
            let label = result.meta.credentials[result.groupId]?.label ?? result.groupId
            let record = MetadataChangeRecord(caller: callerName, groupId: result.groupId, label: label, changes: result.changes)
            try? changeLog.append(record)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            NotificationCenter.default.post(name: .metadataEditedByCaller, object: record)
            return .init(success: true, groupId: result.groupId, changes: result.changes)
        } catch let error as LocalizedError {
            return .init(success: false, error: error.errorDescription ?? "\(error)")
        } catch {
            return .init(success: false, error: error.localizedDescription)
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
                    error: Self.unlockFailureMessage(vaultInitialized: session.isVaultInitialized),
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
            var result = response(for: session.status())
            if request.inspectValues == true, let inspector = session as? any CredentialSessionManaging {
                result.valueInventory = (try? inspector.inspectValueInventory())?.mapValues { $0.sorted() }
            }
            return result
        }
    }

    /// Never echoes the passphrase; does say whether there is a vault to unlock at all.
    static func unlockFailureMessage(vaultInitialized: Bool) -> String {
        vaultInitialized
            ? "Wrong passphrase, or the vault could not be opened. Try again, or use your recovery key in the KeyKeeper app."
            : "No vault yet. Click the KeyKeeper icon in the menu bar and create one first."
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

    nonisolated static func isClientConnected(_ fd: Int32) -> Bool {
        var byte: UInt8 = 0
        let result = recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
        return result > 0 || (result < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
    }

    /// A waiting approval is bound to the complete vault revision, including secret-only changes.
    func captureVaultEpoch() throws -> UInt64? { try accessGate?.captureEpoch() }

    private func withVaultAccess<T>(expectedEpoch: UInt64? = nil, requireEpoch: Bool = false,
                                    _ body: () throws -> T) throws -> T {
        guard let accessGate else { return try body() }
        guard !requireEpoch || expectedEpoch != nil else { throw VaultAccessError.staleEpoch }
        return try accessGate.withAccess(expectedEpoch: expectedEpoch, body)
    }

    func handleAuthRequest(_ request: AuthRequest,
                           clientFd: Int32,
                           callerIdentity: CallerIdentity) {
        do {
            try withVaultAccess {
                try handleAuthRequestAdmitted(request, clientFd: clientFd, callerIdentity: callerIdentity,
                                              vaultEpoch: captureVaultEpoch())
            }
        } catch {
            send(.auth(.init(granted: false, error: error.localizedDescription)), clientFd: clientFd)
        }
    }

    private func handleAuthRequestAdmitted(_ request: AuthRequest, clientFd: Int32,
                                           callerIdentity: CallerIdentity, vaultEpoch: UInt64?) {
        var enrichedRequest = request
        enrichedRequest.pid = callerIdentity.peerPID
        enrichedRequest.callerIdentity = callerIdentity
        // Never trust a string that arrived over the socket, even if the CLI sanitized it.
        enrichedRequest.statedReason = CallerStatedReason.sanitize(request.statedReason?.text)

        // 【曾经的 bug】窗口上的凭据名和字段名原样用调用方自报的值，从不和本地核对：一个进程
        // 可以一边申请 aws-prod-root、一边让弹窗写「OpenAI 测试 key」，把用户骗去点允许。
        // 名字一律以 meta 为准；字段显示这条凭据全部机密字段，因为 strict 授权就是按凭据发的。
        let meta: MetaFile
        do { meta = try metaStore.loadForUse() }
        catch {
            send(.auth(AuthResponse(granted: false, error: error.localizedDescription)), clientFd: clientFd)
            return
        }
        guard let credentialId = meta.resolveGroupId(request.credentialId),
              let credential = meta.credentials[credentialId] else {
            send(.auth(AuthResponse(granted: false, error: "Credential or field not found")), clientFd: clientFd)
            return
        }
        enrichedRequest.credentialId = credentialId
        enrichedRequest.credentialLabel = credential.label
        enrichedRequest.fieldNames = credential.fields.filter { $0.value.secret }.keys.sorted()
        let fingerprint: Data
        do { fingerprint = try Self.metadataFingerprint(credential) }
        catch {
            send(.auth(.init(granted: false, error: AuthorizationMetadataError.changed.localizedDescription)), clientFd: clientFd)
            return
        }

        if let refusal = AccessPolicy.strictRefusal(for: callerIdentity.subject.fingerprint) {
            send(.auth(AuthResponse(granted: false, error: refusal)), clientFd: clientFd)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.clipboardSaveController?.isPending != true, self.browserSessionController?.isPending != true, self.envImportController?.isPending != true, envImportController?.isPending != true else {
                self.send(.auth(.init(granted: false, error: ClipboardSaveError.busy.localizedDescription)), clientFd: clientFd)
                return
            }
            self.refreshPending()

            let now = Date()
            let pending = PendingAuthRequest(
                id: UUID().uuidString,
                request: enrichedRequest,
                clientFd: clientFd,
                requestedAt: now,
                metadataFingerprint: fingerprint,
                vaultEpoch: vaultEpoch
            )

            // Another prompt is on screen: wait for it instead of failing the caller.
            if self.pendingRequest != nil || self.pendingServiceRequest != nil {
                self.enqueueWaiting(.auth(pending))
                return
            }

            self.pendingRequest = pending
            self.scheduleConnectionWatch()
        }
    }

    private func enqueueWaiting(_ item: WaitingAuthorization) {
        guard waiting.count < Self.maximumWaiting else {
            switch item {
            case .auth(let pending):
                send(
                    IPCResponse.auth(AuthResponse(granted: false, error: Self.busyMessage)),
                    clientFd: pending.clientFd
                )
            case .service(let pending):
                send(
                    IPCResponse.value(ValueResponse(
                        success: false,
                        error: Self.busyMessage,
                        errorCode: .noAuthorization
                    )),
                    clientFd: pending.clientFd
                )
            }
            return
        }
        waiting.append(item)
        waitingCount = waiting.count
    }

    /// Shows the next live request once the current prompt has been answered or abandoned.
    private func promoteNextWaiting() {
        guard pendingRequest == nil, pendingServiceRequest == nil else { return }
        while !waiting.isEmpty {
            let next = waiting.removeFirst()
            waitingCount = waiting.count
            if !Self.isClientConnected(next.clientFd) {
                finish(next, at: Date())
                continue
            }
            switch next {
            case .auth(let pending):
                pendingRequest = pending
            case .service(let pending):
                pendingServiceRequest = pending
            }
            scheduleConnectionWatch()
            return
        }
    }

    func handleValueRequest(_ request: ValueRequest,
                            clientFd: Int32,
                            callerIdentity: CallerIdentity) {
        do {
            try withVaultAccess {
                try handleValueRequestAdmitted(request, clientFd: clientFd, callerIdentity: callerIdentity,
                                               vaultEpoch: captureVaultEpoch())
            }
        } catch {
            Self.writeAndClose(.value(.init(success: false, error: error.localizedDescription,
                errorCode: .keychainError, storageErrorCode: .readFailed)), clientFd: clientFd)
        }
    }

    private func handleValueRequestAdmitted(_ request: ValueRequest, clientFd: Int32,
                                            callerIdentity: CallerIdentity, vaultEpoch: UInt64?) {
        // Load credential metadata to check security level. Earlier group IDs and field names
        // resolve to the current ones, which is what grants and values are keyed by.
        let meta: MetaFile
        do { meta = try metaStore.loadForUse() }
        catch {
            Self.writeAndClose(.value(.init(success: false, error: error.localizedDescription,
                errorCode: .keychainError, storageErrorCode: .readFailed)), clientFd: clientFd)
            return
        }
        var request = request
        if let id = meta.resolveGroupId(request.credentialId),
           let field = meta.credentials[id]?.resolveFieldName(request.fieldName) {
            let requested = request.requestedFieldNames.map { meta.credentials[id]?.resolveFieldName($0) ?? $0 }
            request = ValueRequest(credentialId: id, fieldName: field, sessionId: request.sessionId,
                                   requestedFieldNames: requested,
                                   statedReason: request.statedReason,
                                   requestedDuration: request.requestedDuration,
                                   commandSummary: request.commandSummary,
                                   purpose: request.purpose)
        }
        request.statedReason = CallerStatedReason.sanitize(request.statedReason?.text)
        // Use the exact snapshot that was verified above, including alias resolution.
        guard let cred = meta.credentials[request.credentialId],
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

        // Inject-only: only KeyKeeper's own CLI, only for `run`. Decided before approvals are
        // consulted, so a refusal spends nothing and prompts nobody.
        if let refusal = InjectOnlyPolicy.refusal(credential: cred, purpose: request.purpose, caller: callerIdentity) {
            Self.writeAndClose(IPCResponse.value(ValueResponse(success: false, error: refusal, errorCode: .injectOnly)), clientFd: clientFd)
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

        let requestID = UUID().uuidString
        do {
            switch try AccessPolicy.decide(credential: cred, credentialId: request.credentialId,
                                           field: request.fieldName, caller: callerIdentity,
                                           terminalSession: request.sessionId, store: approvals,
                                           reason: request.statedReason?.text,
                                           command: request.commandSummary.map { CallerStatedReason.printableLine($0, limit: 200) },
                                           requestID: requestID) {
            case .allowed(let approval):
                Self.readValueAndRespond(request: request, clientFd: clientFd, session: session,
                                         matched: approval, approvals: approvals)
            case .needsApproval where cred.security == .strict:
                // A strict credential is approved through the auth request, which the CLI sends
                // on seeing this; the prompt is not raised from a value read.
                Self.writeAndClose(IPCResponse.value(ValueResponse(
                    success: false, error: "No valid grant", errorCode: .noAuthorization)), clientFd: clientFd)
            case .needsApproval:
                // A request with no stated reason still gets its window; the window says so.
                enqueueServiceRequest(request, credential: cred, clientFd: clientFd,
                                      callerIdentity: callerIdentity, id: requestID, vaultEpoch: vaultEpoch)
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
                                       callerIdentity: CallerIdentity,
                                       id: String, vaultEpoch: UInt64?) {
        let fingerprint: Data
        do { fingerprint = try Self.metadataFingerprint(credential) }
        catch {
            Self.writeAndClose(.value(.init(success: false, error: AuthorizationMetadataError.changed.localizedDescription,
                errorCode: .keychainError, storageErrorCode: .readFailed)), clientFd: clientFd)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.clipboardSaveController?.isPending != true, self.browserSessionController?.isPending != true, self.envImportController?.isPending != true, envImportController?.isPending != true else {
                self.send(.value(.init(success: false, error: ClipboardSaveError.busy.localizedDescription,
                    errorCode: .noAuthorization)), clientFd: clientFd)
                return
            }
            self.refreshPending()

            let requestedFields = self.validRequestedFields(
                request.requestedFieldNames,
                currentFieldName: request.fieldName,
                credential: credential
            )
            let now = Date()
            let pending = PendingServiceRequest(
                id: id,
                request: request,
                clientFd: clientFd,
                credentialId: request.credentialId,
                credentialLabel: credential.label,
                fieldNames: requestedFields,
                callerIdentity: callerIdentity,
                requestedAt: now,
                metadataFingerprint: fingerprint,
                vaultEpoch: vaultEpoch
            )

            if self.pendingRequest != nil || self.pendingServiceRequest != nil {
                self.enqueueWaiting(.service(pending))
                return
            }

            self.pendingServiceRequest = pending
            self.scheduleConnectionWatch()
        }
    }

    private func handleServiceRequestsList(clientFd: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshPending()
            var summaries = self.pendingServiceRequest.map { [$0.summary] } ?? []
            for item in self.waiting {
                if case .service(let pending) = item {
                    summaries.append(pending.summary)
                }
            }
            self.send(
                IPCResponse.serviceRequests(ServiceRequestsListResponse(
                    requests: summaries.map { $0.redactedForCaller() })),
                clientFd: clientFd
            )
        }
    }

    private nonisolated static func readValueAndRespond(request: ValueRequest, clientFd: Int32,
                                                        session: SessionControlling,
                                                        matched: Approval?, approvals: ApprovalStore) {
        let response = retrieveSessionValue(
            session: session,
            credentialId: request.credentialId,
            fieldName: request.fieldName
        )
        // Only a value that was actually handed out spends a "once" approval.
        if response.success, let matched {
            try? approvals.noteUse(id: matched.id, field: request.fieldName)
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

    /// How often an on-screen approval checks that its requester is still connected.
    static let connectionWatchInterval: TimeInterval = 1

    /// A request stays actionable while its calling process waits. A clock deadline must
    /// never turn an unanswered, still-live request into a denial.
    private func isFinished(_ item: WaitingAuthorization) -> Bool {
        !Self.isClientConnected(item.clientFd)
    }

    /// A dead caller can never be authorized retroactively. Keep a metadata-only record
    /// of what was missed, then release its socket.
    private func finish(_ item: WaitingAuthorization, at now: Date) {
        recordMissed(item, at: now)
        let fd = item.clientFd
        queue.async { close(fd) }
    }

    private func recordMissed(_ item: WaitingAuthorization, at now: Date) {
        let credentialId: String
        let fieldNames: [String]
        let caller: CallerIdentity
        let reason: String?
        let requestID: String
        switch item {
        case .auth(let pending):
            requestID = pending.id
            credentialId = pending.request.credentialId
            fieldNames = pending.request.fieldNames
            guard let identity = pending.request.callerIdentity else { return }
            caller = identity
            reason = pending.request.statedReason?.text
        case .service(let pending):
            requestID = pending.id
            credentialId = pending.credentialId
            fieldNames = pending.fieldNames
            caller = pending.callerIdentity
            reason = pending.request.statedReason?.text
        }
        let event = ServiceAuditEvent(
            timestamp: now, credentialId: credentialId, fieldName: fieldNames.joined(separator: ", "),
            subjectFingerprint: caller.subjectFingerprint, subjectDisplayName: caller.displayName,
            mode: .enforced, decision: "missed_approval", reason: CallerStatedReason.sanitize(reason)?.text,
            requestID: requestID
        )
        do {
            try approvals.recordAudit(event)
        } catch {
            // A failed Keychain write cannot be represented as a saved history item.
            UserDefaults.standard.set(true, forKey: "missedApprovalRecordError")
        }
        NotificationCenter.default.post(name: .authorizationMissed, object: nil)
    }

    func refreshPending(now: Date = Date()) {
        if let pending = pendingRequest, isFinished(.auth(pending)) {
            pendingRequest = nil
            finish(.auth(pending), at: now)
        }

        if let pending = pendingServiceRequest, isFinished(.service(pending)) {
            pendingServiceRequest = nil
            finish(.service(pending), at: now)
        }

        let expiredWaiting = waiting.filter { isFinished($0) }
        if !expiredWaiting.isEmpty {
            waiting.removeAll { isFinished($0) }
            waitingCount = waiting.count
            expiredWaiting.forEach { finish($0, at: now) }
        }

        promoteNextWaiting()
        scheduleConnectionWatch()
    }

    private var connectionWatchScheduled = false

    private func scheduleConnectionWatch() {
        guard !connectionWatchScheduled,
              pendingRequest != nil || pendingServiceRequest != nil || !waiting.isEmpty else { return }
        connectionWatchScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectionWatchInterval) { [weak self] in
            guard let self else { return }
            self.connectionWatchScheduled = false
            self.refreshPending()
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

    /// The peer's audit token, taken from the socket itself.
    ///
    /// A pid alone says who is at the other end *right now*; by the time we look it up, that
    /// process may have exec'd into something more trustworthy while a sibling holds this
    /// connection. The token carries the pidversion too, so the code identity it resolves to is
    /// the one that made the connection.
    private func peerAuditToken(for fd: Int32) -> Data? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        let result = withUnsafeMutablePointer(to: &token) { pointer in
            getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, pointer, &length)
        }
        guard result == 0, length == socklen_t(MemoryLayout<audit_token_t>.size) else { return nil }
        return withUnsafeBytes(of: token) { Data($0) }
    }

    private nonisolated static func writeAndClose(_ response: IPCResponse, clientFd: Int32) {
        try? IPCMessage.writeMessage(fd: clientFd, message: response, deadline: IPCMessage.messageDeadline)
        close(clientFd)
    }
}

extension Notification.Name {
    /// Posted with a `MetadataChangeRecord` after an agent or script renamed or re-described a key.
    static let metadataEditedByCaller = Notification.Name("KeyKeeper.metadataEditedByCaller")
    /// A connected caller left before the person answered its authorization request.
    static let authorizationMissed = Notification.Name("KeyKeeper.authorizationMissed")
}
