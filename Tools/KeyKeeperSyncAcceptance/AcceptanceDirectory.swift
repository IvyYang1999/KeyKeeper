#if KEYKEEPER_SYNC_ACCEPTANCE
import Foundation
import Darwin

/// Fixed, private, UUID-derived test directory. No alternate path or production fallback.
final class AcceptanceDirectory {
    private let fd: Int32
    init(options: AcceptanceOptions, create: Bool) throws {
        let root = options.directory
        if create {
            guard mkdir(root.path, 0o700) == 0 || errno == EEXIST else { throw AcceptanceFailure.isolation }
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o700,
              let physical = realpath(root.path, nil) else { throw AcceptanceFailure.isolation }
        defer { free(physical) }
        guard String(cString: physical) == root.path else { throw AcceptanceFailure.isolation }
        fd = Darwin.open(root.appendingPathComponent(".acceptance.lock").path,
                         O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AcceptanceFailure.isolation }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw AcceptanceFailure.isolation
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}
#endif
