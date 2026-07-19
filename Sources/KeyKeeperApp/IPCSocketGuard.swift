import Foundation

enum IPCSocketAcquisition {
    case acquired(IPCSocketListener, IPCSocketAcquisitionDisposition)
    case anotherInstanceRunning
}

enum IPCSocketAcquisitionDisposition: Equatable {
    case freshSocket
    case replacedStaleSocket
}

enum IPCSocketPathObservation: Equatable {
    case missing
    case connected
    case connectionRefused(nodeIsSocket: Bool, nodeIsUnchanged: Bool)
}

enum IPCSocketTakeoverDecision: Equatable {
    case bindFreshSocket
    case replaceStaleSocket
    case reportAnotherInstance
    case refuseReplacement
}

enum IPCSocketTakeoverPolicy {
    static func decide(for observation: IPCSocketPathObservation) -> IPCSocketTakeoverDecision {
        switch observation {
        case .missing:
            return .bindFreshSocket
        case .connected:
            return .reportAnotherInstance
        case .connectionRefused(nodeIsSocket: true, nodeIsUnchanged: true):
            return .replaceStaleSocket
        case .connectionRefused:
            return .refuseReplacement
        }
    }
}

enum IPCSocketGuardError: LocalizedError {
    case pathTooLong(String)
    case unexpectedNode(String)
    case unsafeLockFile(String)
    case systemCall(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .pathTooLong(let path):
            return "Unix socket path is too long: \(path)"
        case .unexpectedNode(let path):
            return "Refusing to replace a non-socket node at \(path)"
        case .unsafeLockFile(let path):
            return "Refusing to use an unsafe socket lock file at \(path)"
        case .systemCall(let operation, let code):
            let message = NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
            return "\(operation) failed: \(message)"
        }
    }
}

/// Owns one bound Unix-domain listening socket and removes only its own filesystem node.
final class IPCSocketListener {
    private let stateLock = NSLock()
    private let identity: IPCSocketFileIdentity
    private(set) var fileDescriptor: Int32
    let path: String

    fileprivate init(fileDescriptor: Int32, path: String, identity: IPCSocketFileIdentity) {
        self.fileDescriptor = fileDescriptor
        self.path = path
        self.identity = identity
    }

    func close() {
        stateLock.lock()
        guard fileDescriptor >= 0 else {
            stateLock.unlock()
            return
        }
        let descriptorToClose = fileDescriptor
        fileDescriptor = -1
        stateLock.unlock()

        IPCSocketGuard.release(
            fileDescriptor: descriptorToClose,
            path: path,
            identity: identity
        )
    }

    deinit {
        close()
    }
}

/// Decides whether to bind, replace a stale socket, or leave a healthy instance untouched.
enum IPCSocketGuard {
    static func acquire(path: String, backlog: Int32 = 5) throws -> IPCSocketAcquisition {
        _ = try socketAddress(for: path)

        return try withStartupLock(for: path) {
            let initialNode = try nodeMetadata(at: path)
            let observation: IPCSocketPathObservation
            var disposition = IPCSocketAcquisitionDisposition.freshSocket

            if let initialNode {
                switch try probe(path: path) {
                case .connected:
                    observation = .connected

                case .missing:
                    observation = .missing

                case .connectionRefused:
                    if let currentNode = try nodeMetadata(at: path) {
                        observation = .connectionRefused(
                            nodeIsSocket: initialNode.isSocket && currentNode.isSocket,
                            nodeIsUnchanged: currentNode.identity == initialNode.identity
                        )
                    } else {
                        observation = .missing
                    }
                }
            } else {
                observation = .missing
            }

            switch IPCSocketTakeoverPolicy.decide(for: observation) {
            case .reportAnotherInstance:
                return .anotherInstanceRunning

            case .replaceStaleSocket:
                guard unlink(path) == 0 else {
                    throw systemCallError("unlink stale socket")
                }
                disposition = .replacedStaleSocket

            case .bindFreshSocket:
                break

            case .refuseReplacement:
                if initialNode?.isSocket == false {
                    throw IPCSocketGuardError.unexpectedNode(path)
                } else {
                    throw IPCSocketGuardError.systemCall(
                        operation: "socket node changed during stale probe",
                        code: EBUSY
                    )
                }
            }

            let listener = try bindAndListen(path: path, backlog: backlog)
            return .acquired(listener, disposition)
        }
    }

    fileprivate static func release(
        fileDescriptor: Int32,
        path: String,
        identity: IPCSocketFileIdentity
    ) {
        let cleanup = {
            removeNodeIfOwned(path: path, identity: identity)
            _ = Darwin.shutdown(fileDescriptor, SHUT_RDWR)
            _ = Darwin.close(fileDescriptor)
        }

        do {
            try withStartupLock(for: path, cleanup)
        } catch {
            // The descriptor must still be closed even if the auxiliary lock cannot be acquired.
            cleanup()
        }
    }

    private static func bindAndListen(path: String, backlog: Int32) throws -> IPCSocketListener {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw systemCallError("socket") }

        var boundIdentity: IPCSocketFileIdentity?
        do {
            let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
            guard descriptorFlags >= 0,
                  fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
                throw systemCallError("fcntl FD_CLOEXEC")
            }

            var address = try socketAddress(for: path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.bind(
                        fileDescriptor,
                        socketPointer,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else { throw systemCallError("bind") }

            guard let node = try nodeMetadata(at: path), node.isSocket else {
                throw IPCSocketGuardError.unexpectedNode(path)
            }
            boundIdentity = node.identity

            guard chmod(path, 0o600) == 0 else { throw systemCallError("chmod socket") }
            guard Darwin.listen(fileDescriptor, backlog) == 0 else {
                throw systemCallError("listen")
            }

            return IPCSocketListener(
                fileDescriptor: fileDescriptor,
                path: path,
                identity: node.identity
            )
        } catch {
            _ = Darwin.close(fileDescriptor)
            if let boundIdentity {
                removeNodeIfOwned(path: path, identity: boundIdentity)
            }
            throw error
        }
    }

    private static func probe(path: String) throws -> SocketProbeResult {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw systemCallError("probe socket") }
        defer { _ = Darwin.close(fileDescriptor) }

        var address = try socketAddress(for: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(
                    fileDescriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        if result == 0 {
            return .connected
        }

        switch errno {
        case ECONNREFUSED:
            return .connectionRefused
        case ENOENT:
            return .missing
        default:
            throw systemCallError("connect probe")
        }
    }

    private static func socketAddress(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw IPCSocketGuardError.pathTooLong(path)
        }

        withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
            pathBytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(sunPathPointer).copyMemory(
                    from: source.baseAddress!,
                    byteCount: source.count
                )
            }
        }
        return address
    }

    private static func nodeMetadata(at path: String) throws -> SocketNodeMetadata? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw systemCallError("lstat socket")
        }

        return SocketNodeMetadata(
            identity: IPCSocketFileIdentity(device: metadata.st_dev, inode: metadata.st_ino),
            isSocket: metadata.st_mode & S_IFMT == S_IFSOCK
        )
    }

    private static func removeNodeIfOwned(path: String, identity: IPCSocketFileIdentity) {
        guard let currentNode = try? nodeMetadata(at: path),
              currentNode.identity == identity else {
            return
        }
        _ = unlink(path)
    }

    private static func withStartupLock<T>(
        for socketPath: String,
        _ body: () throws -> T
    ) throws -> T {
        let lockPath = socketPath + ".lock"
        let lockFileDescriptor = Darwin.open(
            lockPath,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard lockFileDescriptor >= 0 else { throw systemCallError("open socket lock") }
        defer { _ = Darwin.close(lockFileDescriptor) }

        var metadata = stat()
        guard fstat(lockFileDescriptor, &metadata) == 0 else {
            throw systemCallError("fstat socket lock")
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG else {
            throw IPCSocketGuardError.unsafeLockFile(lockPath)
        }
        guard fchmod(lockFileDescriptor, 0o600) == 0 else {
            throw systemCallError("chmod socket lock")
        }

        var fileLock = flock()
        fileLock.l_start = 0
        fileLock.l_len = 0
        fileLock.l_type = Int16(F_WRLCK)
        fileLock.l_whence = Int16(SEEK_SET)
        while fcntl(lockFileDescriptor, F_SETLKW, &fileLock) != 0 {
            if errno != EINTR { throw systemCallError("lock socket startup") }
        }
        defer {
            fileLock.l_type = Int16(F_UNLCK)
            _ = fcntl(lockFileDescriptor, F_SETLK, &fileLock)
        }

        return try body()
    }

    private static func systemCallError(_ operation: String) -> IPCSocketGuardError {
        IPCSocketGuardError.systemCall(operation: operation, code: errno)
    }
}

private enum SocketProbeResult {
    case connected
    case connectionRefused
    case missing
}

private struct SocketNodeMetadata {
    let identity: IPCSocketFileIdentity
    let isSocket: Bool
}

private struct IPCSocketFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
