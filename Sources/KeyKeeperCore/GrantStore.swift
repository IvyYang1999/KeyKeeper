import Foundation

public final class GrantStore: Sendable {
    private let fileURL: URL

    /// Session grants expire after 24 hours as a safety net
    private static let sessionMaxAge: TimeInterval = 24 * 60 * 60

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("grants.json")
    }

    public static var `default`: GrantStore {
        let dir = KeyKeeperPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return GrantStore(directory: dir)
    }

    // MARK: - File I/O with flock

    private func load() throws -> GrantFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return GrantFile()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GrantFile.self, from: data)
    }

    private func save(_ file: GrantFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Execute a read-write operation under an exclusive file lock.
    private func withFileLock<T>(_ body: (inout GrantFile) throws -> T) throws -> T {
        // Ensure file exists for locking
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try save(GrantFile())
        }

        let fd = open(fileURL.path, O_RDWR)
        guard fd >= 0 else {
            throw GrantStoreError.lockFailed
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw GrantStoreError.lockFailed
        }
        defer { flock(fd, LOCK_UN) }

        var file = try load()
        let result = try body(&file)
        try save(file)
        return result
    }

    // MARK: - Public API

    /// Find a valid grant for the given credential and optional session.
    public func findValidGrant(credentialId: String, sessionId: String?) throws -> Grant? {
        let file = try load()
        let now = Date()
        return file.grants.first { grant in
            guard grant.credentialId == credentialId else { return false }
            return isValid(grant: grant, sessionId: sessionId, now: now)
        }
    }

    /// Add a new grant.
    public func addGrant(_ grant: Grant) throws {
        try withFileLock { file in
            file.grants.append(grant)
        }
    }

    /// Revoke (remove) a grant by ID.
    public func revokeGrant(id: String) throws {
        try withFileLock { file in
            file.grants.removeAll { $0.id == id }
        }
    }

    /// Revoke all grants for a credential.
    public func revokeAllGrants(credentialId: String) throws {
        try withFileLock { file in
            file.grants.removeAll { $0.credentialId == credentialId }
        }
    }

    /// Mark a .once grant as consumed.
    public func consumeGrant(id: String) throws {
        try withFileLock { file in
            if let idx = file.grants.firstIndex(where: { $0.id == id }) {
                file.grants[idx].consumed = true
            }
        }
    }

    /// Remove expired grants.
    public func pruneExpired() throws {
        let now = Date()
        try withFileLock { file in
            file.grants.removeAll { !isValid(grant: $0, sessionId: nil, now: now, ignoreSession: true) }
        }
    }

    /// Get all grants for a credential (for UI display).
    public func grants(for credentialId: String) throws -> [Grant] {
        let file = try load()
        return file.grants.filter { $0.credentialId == credentialId }
    }

    // MARK: - Validation

    private func isValid(grant: Grant, sessionId: String?, now: Date,
                         ignoreSession: Bool = false) -> Bool {
        switch grant.duration {
        case .once:
            return !grant.consumed

        case .session(let grantSessionId):
            // Session grants also have a 24-hour hard cap
            let maxAge = now.timeIntervalSince(grant.createdAt) < Self.sessionMaxAge
            if ignoreSession { return maxAge }
            return sessionId == grantSessionId && maxAge

        case .timed(let expiration):
            return now < expiration

        case .always:
            return true
        }
    }
}

public enum GrantStoreError: Error, LocalizedError {
    case lockFailed

    public var errorDescription: String? {
        switch self {
        case .lockFailed: return "Failed to acquire grants file lock"
        }
    }
}
