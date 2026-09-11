import ArgumentParser
import Darwin
import Foundation
import KeyKeeperCore

/// One locked 0700 directory per run. A separate same-binary guard owns an inherited
/// lock descriptor and waits for parent pipe EOF, including on SIGKILL/crash.
final class CredentialFileLease {
    let directory: URL
    private let lockHandle: FileHandle
    private let liveness = Pipe()
    private let ready = Pipe()
    private let guardProcess = Process()
    private var count = 0
    private var closed = false

    init(executable: URL? = Bundle.main.executableURL) throws {
        let root = try Self.root()
        directory = root.appendingPathComponent("lease-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw Self.failure }
        let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { _ = rmdir(directory.path); throw Self.failure }
        lockHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Self.failure }
        for handle in [liveness.fileHandleForReading, liveness.fileHandleForWriting,
                       ready.fileHandleForReading, ready.fileHandleForWriting] {
            _ = fcntl(handle.fileDescriptor, F_SETFD, FD_CLOEXEC)
        }
        guardProcess.executableURL = executable
        guardProcess.arguments = ["internal-file-guard", directory.path]
        guardProcess.environment = [:] // Never give the cleanup helper any credentials.
        guardProcess.standardInput = liveness
        guardProcess.standardOutput = ready
        guardProcess.standardError = lockHandle // inherited open-file description retains flock
        do {
            try guardProcess.run()
            try liveness.fileHandleForReading.close()
            try ready.fileHandleForWriting.close()
            var event = pollfd(fd: ready.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 5000) > 0,
                  try ready.fileHandleForReading.read(upToCount: 1) == Data([1]) else { throw Self.failure }
        } catch { close(); throw Self.failure }
    }

    func write(_ data: Data) throws -> String {
        guard !closed, guardProcess.isRunning, count < 32, !data.isEmpty,
              data.count <= CredentialFileFormat.maximumBytes else { throw Self.failure }
        let dirFD = try Self.openLease(directory, lockFD: lockHandle.fileDescriptor)
        defer { Darwin.close(dirFD) }
        let name = "credential-\(count).json"
        let fd = openat(dirFD, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.failure }
        count += 1
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.close() }
        catch { _ = unlinkat(dirFD, name, 0); throw Self.failure }
        return directory.appendingPathComponent(name).path
    }

    func closeLivenessChannel() { try? liveness.fileHandleForWriting.close() }

    func close() {
        guard !closed else { return }; closed = true
        closeLivenessChannel()
        let deadline = Date().addingTimeInterval(5)
        while guardProcess.isRunning, Date() < deadline { usleep(10_000) }
        if guardProcess.isRunning { _ = kill(guardProcess.processIdentifier, SIGKILL) }
        Self.cleanup(directory, lockFD: lockHandle.fileDescriptor)
        try? lockHandle.close()
    }
    deinit { close() }

    static var failure: CommandFailure { CommandFailure("Credential file lease failed. No command was started; check local temporary-file access.") }

    static func root() throws -> URL {
        // Use the OS per-user temporary directory, not an inherited TMPDIR override.
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard size > 0, size <= buffer.count else { throw failure }
        let root = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent("keykeeper-credential-files")
        if mkdir(root.path, 0o700) != 0, errno != EEXIST { throw failure }
        let fd = try openPrivateDirectory(root)
        Darwin.close(fd)
        return root
    }

    private static func openPrivateDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        var info = stat()
        guard fd >= 0 else { throw failure }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700 else {
            Darwin.close(fd); throw failure
        }
        return fd
    }

    static func openLease(_ directory: URL, lockFD: Int32) throws -> Int32 {
        guard directory.deletingLastPathComponent().standardizedFileURL.path == (try root()).path,
              directory.lastPathComponent.hasPrefix("lease-"),
              UUID(uuidString: String(directory.lastPathComponent.dropFirst(6))) != nil else { throw failure }
        let dirFD = try openPrivateDirectory(directory)
        var held = stat(); var named = stat()
        guard fstat(lockFD, &held) == 0,
              fstatat(dirFD, "lock", &named, AT_SYMLINK_NOFOLLOW) == 0,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino,
              held.st_mode & S_IFMT == S_IFREG, held.st_uid == getuid(),
              held.st_mode & 0o777 == 0o600 else {
            Darwin.close(dirFD); throw failure
        }
        return dirFD
    }

    static func cleanup(_ directory: URL, lockFD: Int32) {
        guard let dirFD = try? openLease(directory, lockFD: lockFD) else { return }
        defer { Darwin.close(dirFD) }
        // Never recurse, follow symlinks, or remove unrelated files in an unexpected directory.
        for index in 0..<32 { _ = unlinkat(dirFD, "credential-\(index).json", 0) }
        _ = unlinkat(dirFD, "lock", 0)
        _ = rmdir(directory.path)
    }

    static func sweepStale() throws {
        let root = try root()
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else { throw failure }
        for case let directory as URL in entries.prefix(128) {
            let fd = open(directory.appendingPathComponent("lock").path, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { cleanup(directory, lockFD: fd) }
            Darwin.close(fd)
        }
    }
}

struct FileGuardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "internal-file-guard", shouldDisplay: false)
    @Argument var directory: String
    func run() throws {
        // Ignore terminal/session signals; cleanup is driven by the owning CLI's pipe.
        for number in [SIGHUP, SIGINT, SIGTERM, SIGPIPE] { signal(number, SIG_IGN) }
        let url = URL(fileURLWithPath: directory)
        let fd = try CredentialFileLease.openLease(url, lockFD: STDERR_FILENO)
        Darwin.close(fd)
        guard flock(STDERR_FILENO, LOCK_EX | LOCK_NB) == 0 else { throw CredentialFileLease.failure }
        defer { CredentialFileLease.cleanup(url, lockFD: STDERR_FILENO) }
        var byte: UInt8 = 1
        guard Darwin.write(STDOUT_FILENO, &byte, 1) == 1 else { return }
        while true {
            let count = Darwin.read(STDIN_FILENO, &byte, 1)
            if count == 0 { break }
            if count < 0, errno != EINTR { break }
        }
    }
}
