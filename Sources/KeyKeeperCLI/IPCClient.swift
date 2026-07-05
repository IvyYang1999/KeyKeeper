import Foundation
import KeyKeeperCore

enum IPCClient {
    /// Request authorization from the KeyKeeper app via Unix socket.
    static func requestAuthorization(_ request: AuthRequest) throws -> AuthResponse {
        let fd = try connectWithRetry(launchIfNeeded: true)
        defer { close(fd) }

        // Set read timeout
        var timeout = timeval(tv_sec: Int(IPCConstants.authTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        // Send envelope
        try IPCMessage.writeMessage(fd: fd, message: IPCRequest.auth(request))

        // Read envelope
        guard let response = IPCMessage.readMessage(fd: fd, as: IPCResponse.self),
              case .auth(let authResponse) = response else {
            throw IPCError.timeout
        }
        return authResponse
    }

    /// Request a secret value from the KeyKeeper app (App reads Keychain on our behalf).
    static func requestValue(credentialId: String, fieldName: String,
                             sessionId: String?,
                             requestedFieldNames: [String]? = nil) throws -> String {
        let fd = try connectWithRetry(launchIfNeeded: true)
        defer { close(fd) }

        var timeout = timeval(tv_sec: Int(IPCConstants.authTimeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let request = ValueRequest(
            credentialId: credentialId,
            fieldName: fieldName,
            sessionId: sessionId,
            requestedFieldNames: requestedFieldNames
        )
        try IPCMessage.writeMessage(fd: fd, message: IPCRequest.value(request))

        guard let response = IPCMessage.readMessage(fd: fd, as: IPCResponse.self),
              case .value(let valueResponse) = response else {
            throw IPCError.appNotResponding
        }

        guard valueResponse.success, let value = valueResponse.value else {
            switch valueResponse.errorCode {
            case .noAuthorization, .authorizationDenied, .pendingExpired:
                throw IPCError.noAuthorization(valueResponse.error)
            case .keychainBlocked, .keychainError:
                throw IPCError.keychainBlocked(valueResponse.error)
            case .invalidRequest, .notFound, .none:
                throw IPCError.denied(valueResponse.error)
            }
        }
        return value
    }

    static func requestPendingServiceRequests() throws -> [PendingServiceRequestSummary] {
        let fd = try connectWithRetry(launchIfNeeded: false)
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        try IPCMessage.writeMessage(fd: fd, message: IPCRequest.serviceRequests(ServiceRequestsListRequest()))
        guard let response = IPCMessage.readMessage(fd: fd, as: IPCResponse.self),
              case .serviceRequests(let listResponse) = response else {
            throw IPCError.appNotResponding
        }
        return listResponse.requests
    }

    // MARK: - Connection

    private static func connectWithRetry(launchIfNeeded: Bool) throws -> Int32 {
        let socketPath = IPCConstants.socketPath
        var fd = connectToSocket(path: socketPath)
        if fd < 0, launchIfNeeded {
            tryLaunchApp()
            for delay in [0.5, 1.0, 2.0] {
                Thread.sleep(forTimeInterval: delay)
                fd = connectToSocket(path: socketPath)
                if fd >= 0 { break }
            }
        }
        guard fd >= 0 else { throw IPCError.appNotRunning }
        return fd
    }

    private static func connectToSocket(path: String) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8.prefix(103)) + [0]
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            pathBytes.withUnsafeBufferPointer { srcBuf in
                let dest = UnsafeMutableRawPointer(sunPathPtr)
                dest.copyMemory(from: srcBuf.baseAddress!, byteCount: pathBytes.count)
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if result != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private static func tryLaunchApp() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "KeyKeeper"]
        try? process.run()
        process.waitUntilExit()
    }
}
