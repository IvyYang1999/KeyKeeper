import Foundation
import Security
import Darwin

/// Only the signed new App may launch the old-identity read-only helper. Values stay in this
/// owned private pipe; environment, arguments and diagnostics never carry source contents.
public enum IdentityMigrationBridge {
    public static func read(from helperURL: URL) async throws -> IdentityMigrationSource {
        try await Task.detached(priority: .userInitiated) { try readSynchronously(from: helperURL) }.value
    }
    static func readSynchronously(from helperURL: URL) throws -> IdentityMigrationSource {
        try IdentityMigrationSignature.current(.current)
        try IdentityMigrationSignature.file(helperURL, identity: .legacy)
        let process = Process(), output = Pipe()
        process.executableURL = helperURL
        process.arguments = []
        let fixture = try IdentityMigrationFixture.resolve(environment: ProcessInfo.processInfo.environment)
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(fixture?.environment ?? [:]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        defer {
            output.fileHandleForReading.closeFile()
            if process.isRunning {
                process.terminate()
                if ended.wait(timeout: .now() + 1) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 1)
                }
            }
        }
        let bytes = try IdentityMigrationPipe.read(output.fileHandleForReading.fileDescriptor, seconds: 30)
        guard ended.wait(timeout: .now() + 1) == .success, !process.isRunning else { throw IdentityMigrationError.unavailable }
        guard process.terminationStatus == 0 else {
            if let error = IdentityMigrationError.fromExit(process.terminationStatus) { throw error }
            throw IdentityMigrationError.unavailable
        }
        return try IdentityMigrationSource.decode(bytes)
    }
}

public enum IdentityMigrationSignature {
    private static func requirement(_ identity: StorageIdentity) throws -> SecRequirement {
        var requirement: SecRequirement?
        let value = "anchor apple generic and identifier \"\(identity.rawValue)\" and certificate leaf[subject.OU] = \"\(StorageIdentity.team)\""
        guard SecRequirementCreateWithString(value as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw IdentityMigrationError.identity }
        return requirement
    }
    public static func current(_ identity: StorageIdentity) throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(identity)) == errSecSuccess else { throw IdentityMigrationError.identity }
    }
    public static func parent() throws {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: getppid())]
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(.current)) == errSecSuccess else { throw IdentityMigrationError.identity }
    }
    public static func file(_ url: URL, identity: StorageIdentity) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), try requirement(identity)) == errSecSuccess else {
            throw IdentityMigrationError.identity
        }
    }
}

public enum IdentityMigrationPipe {
    public static func read(_ fd: Int32, seconds: UInt64) throws -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw IdentityMigrationError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&descriptor, 1, 50)
            guard polled >= 0 || errno == EINTR else { throw IdentityMigrationError.unavailable }
            let amount = Darwin.read(fd, &buffer, buffer.count)
            if amount == 0 { return bytes }
            if amount < 0 {
                guard errno == EINTR || errno == EAGAIN else { throw IdentityMigrationError.unavailable }
                continue
            }
            guard bytes.count + amount <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.malformed }
            bytes.append(contentsOf: buffer.prefix(amount))
        }
        throw IdentityMigrationError.unavailable
    }
    public static func write(_ data: Data, fd: Int32, seconds: UInt64) throws {
        guard data.count <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.malformed }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw IdentityMigrationError.unavailable }
        let deadline = DispatchTime.now().uptimeNanoseconds + seconds * 1_000_000_000
        var offset = 0
        while offset < data.count, DispatchTime.now().uptimeNanoseconds < deadline {
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let polled = poll(&descriptor, 1, 50)
            guard polled >= 0 || errno == EINTR else { throw IdentityMigrationError.unavailable }
            let amount = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if amount < 0 {
                guard errno == EINTR || errno == EAGAIN else { throw IdentityMigrationError.unavailable }
                continue
            }
            offset += amount
        }
        guard offset == data.count else { throw IdentityMigrationError.unavailable }
    }
}

extension IdentityMigrationError {
    public var exitCode: Int32 {
        switch self {
        case .unavailable: 70
        case .malformed: 71
        case .unsignedMetadata: 72
        case .activeImport: 73
        case .sourceChanged: 74
        case .destinationConflict: 75
        case .legacyRunning: 76
        case .identity: 77
        }
    }
    static func fromExit(_ value: Int32) -> Self? {
        [Self.unavailable, .malformed, .unsignedMetadata, .activeImport, .sourceChanged, .destinationConflict, .legacyRunning, .identity]
            .first { $0.exitCode == value }
    }
}
