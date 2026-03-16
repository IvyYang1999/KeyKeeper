import Foundation
import KeyKeeperCore

/// Unix domain socket server that receives authorization requests from CLI.
@MainActor
final class IPCServer: ObservableObject {
    @Published var pendingRequest: PendingAuthRequest?

    private var listenFd: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "keykeeper.ipc", qos: .userInitiated)

    struct PendingAuthRequest {
        let request: AuthRequest
        let clientFd: Int32
    }

    func start() {
        let path = IPCConstants.socketPath

        // Remove stale socket
        unlink(path)

        // Create socket
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { return }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8.prefix(103)) + [0]
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { srcBuf in
                let dest = UnsafeMutableRawPointer(sunPathPtr)
                dest.copyMemory(from: srcBuf.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenFd)
            listenFd = -1
            return
        }

        // Set permissions so only current user can connect
        chmod(path, 0o600)

        // Listen
        guard Darwin.listen(listenFd, 5) == 0 else {
            close(listenFd)
            listenFd = -1
            return
        }

        // Accept connections via GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: listenFd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.listenFd, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        listenSource = source
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        unlink(IPCConstants.socketPath)
    }

    /// Send response back to the CLI client.
    func respond(to pending: PendingAuthRequest, with response: AuthResponse) {
        queue.async {
            try? IPCMessage.writeMessage(fd: pending.clientFd, message: IPCResponse.auth(response))
            close(pending.clientFd)
        }
        pendingRequest = nil
    }

    /// Deny the current pending request.
    func denyPending() {
        guard let pending = pendingRequest else { return }
        respond(to: pending, with: AuthResponse(granted: false, error: "User denied"))
    }

    // MARK: - Private

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(listenFd, sockPtr, &clientLen)
            }
        }
        guard clientFd >= 0 else { return }

        // Read envelope
        guard let envelope = IPCMessage.readMessage(fd: clientFd, as: IPCRequest.self) else {
            let response = IPCResponse.auth(AuthResponse(granted: false, error: "Invalid request"))
            try? IPCMessage.writeMessage(fd: clientFd, message: response)
            close(clientFd)
            return
        }

        switch envelope {
        case .auth(let request):
            handleAuthRequest(request, clientFd: clientFd)
        case .value(let request):
            handleValueRequest(request, clientFd: clientFd)
        }
    }

    private func handleAuthRequest(_ request: AuthRequest, clientFd: Int32) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // If there's already a pending request, deny the new one
            if self.pendingRequest != nil {
                let response = IPCResponse.auth(
                    AuthResponse(granted: false, error: "Another authorization is in progress"))
                self.queue.async {
                    try? IPCMessage.writeMessage(fd: clientFd, message: response)
                    close(clientFd)
                }
                return
            }

            self.pendingRequest = PendingAuthRequest(request: request, clientFd: clientFd)
        }
    }

    private func handleValueRequest(_ request: ValueRequest, clientFd: Int32) {
        queue.async {
            let store = MetaStore.default
            let grantStore = GrantStore.default
            let keychain = KeychainService()

            // Load credential metadata to check security level
            guard let meta = try? store.load(),
                  let cred = meta.credentials[request.credentialId],
                  let field = cred.fields[request.fieldName],
                  field.secret else {
                let resp = IPCResponse.value(
                    ValueResponse(success: false, error: "Credential or field not found"))
                try? IPCMessage.writeMessage(fd: clientFd, message: resp)
                close(clientFd)
                return
            }

            // For strict credentials, verify grant
            if cred.security == .strict {
                guard let sessionId = request.sessionId,
                      let _ = try? grantStore.findValidGrant(
                          credentialId: request.credentialId, sessionId: sessionId) else {
                    let resp = IPCResponse.value(
                        ValueResponse(success: false, error: "No valid grant"))
                    try? IPCMessage.writeMessage(fd: clientFd, message: resp)
                    close(clientFd)
                    return
                }
            }

            // Read from Keychain (App is the owner, no ACL prompt)
            do {
                let value = try keychain.retrieve(
                    credentialId: request.credentialId, fieldName: request.fieldName)
                let resp = IPCResponse.value(ValueResponse(success: true, value: value))
                try? IPCMessage.writeMessage(fd: clientFd, message: resp)
            } catch {
                let resp = IPCResponse.value(
                    ValueResponse(success: false, error: error.localizedDescription))
                try? IPCMessage.writeMessage(fd: clientFd, message: resp)
            }
            close(clientFd)
        }
    }
}
