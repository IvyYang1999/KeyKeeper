import Foundation
import Darwin
import KeyKeeperCore

/// Uses the same startup fcntl lock as the old App, held for the complete read-only transfer.
/// The listening placeholder makes ordinary old launches report an existing instance.
final class LegacyEndpointLease {
    private let lockFD: Int32
    private let socketFD: Int32
    private let socketPath: String
    private let device: dev_t
    private let inode: ino_t
    init(fixture: IdentityMigrationFixture? = nil) throws {
        let socketPath = fixture?.socket ?? "/tmp/keykeeper-\(NSUserName()).sock"
        self.socketPath = socketPath
        let lockFD = open(socketPath + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw IdentityMigrationError.unavailable }
        var lockInfo = stat(), record = flock()
        record.l_type = Int16(F_WRLCK); record.l_whence = Int16(SEEK_SET)
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_uid == getuid(), lockInfo.st_mode & S_IFMT == S_IFREG,
              fcntl(lockFD, F_SETLK, &record) == 0 else {
            close(lockFD); throw IdentityMigrationError.legacyRunning
        }
        self.lockFD = lockFD
        var fd: Int32 = -1
        var created: stat?
        do {
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(socketPath.utf8) + [0]
            guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw IdentityMigrationError.unavailable }
            withUnsafeMutablePointer(to: &address.sun_path) { pointer in
                pathBytes.withUnsafeBytes { UnsafeMutableRawPointer(pointer).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            }
            func connect(_ descriptor: Int32) -> Int32 {
                withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                } }
            }
            var prior = stat()
            if lstat(socketPath, &prior) == 0 {
                guard prior.st_uid == getuid(), prior.st_mode & S_IFMT == S_IFSOCK else { throw IdentityMigrationError.unavailable }
                let probe = socket(AF_UNIX, SOCK_STREAM, 0)
                guard probe >= 0 else { throw IdentityMigrationError.unavailable }
                defer { close(probe) }
                let flags = fcntl(probe, F_GETFL)
                guard flags >= 0, fcntl(probe, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw IdentityMigrationError.unavailable }
                let result = connect(probe), code = errno
                guard result < 0, code == ECONNREFUSED else { throw IdentityMigrationError.legacyRunning }
                var current = stat()
                guard lstat(socketPath, &current) == 0, current.st_dev == prior.st_dev, current.st_ino == prior.st_ino,
                      unlink(socketPath) == 0 else { throw IdentityMigrationError.unavailable }
            } else if errno != ENOENT { throw IdentityMigrationError.unavailable }
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw IdentityMigrationError.unavailable }
            let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            } }
            guard result == 0 else { throw IdentityMigrationError.legacyRunning }
            var own = stat()
            guard lstat(socketPath, &own) == 0 else { throw IdentityMigrationError.unavailable }
            created = own
            guard chmod(socketPath, 0o600) == 0, listen(fd, 5) == 0 else { throw IdentityMigrationError.unavailable }
            socketFD = fd; device = own.st_dev; inode = own.st_ino
        } catch {
            if fd >= 0 { close(fd) }
            if let created {
                var now = stat()
                if lstat(socketPath, &now) == 0, now.st_dev == created.st_dev, now.st_ino == created.st_ino { _ = unlink(socketPath) }
            }
            close(lockFD)
            throw error
        }
    }
    deinit {
        var now = stat()
        if lstat(socketPath, &now) == 0, now.st_dev == device, now.st_ino == inode { _ = unlink(socketPath) }
        close(socketFD); close(lockFD)
    }
}
