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
    /// The grant that covers this caller, if any.
    ///
    /// `fingerprint` nil means the caller could not be identified: then only a grant that was
    /// never scoped can apply, never one that belongs to somebody else.
    public func findValidGrant(credentialId: String, sessionId: String?,
                               fingerprint: String? = nil) throws -> Grant? {
        let file = try load()
        let now = Date()
        return file.grants.first { grant in
            guard grant.credentialId == credentialId else { return false }
            // An approval with no owner recorded matches nobody.
            //
            // 【曾经的洞】it used to match everybody, on the reasoning that tearing up old
            // approvals would start prompting for agents the person had already allowed. A
            // security audit found what that actually covered on this machine: an unowned
            // "Always" for the Sparkle signing key and for the Apple notarisation password —
            // so any process running as the user could take either with no prompt at all, and
            // the "pin it to whoever used it first" migration handed the approval to the
            // taker. Re-asking once per credential is the cheaper mistake.
            guard let owner = grant.subjectFingerprint, owner == fingerprint else { return false }
            return isValid(grant: grant, sessionId: sessionId, now: now)
        }
    }

    /// Is there any approval that could cover this call, ignoring who it was issued to?
    ///
    /// For the CLI's pre-flight only, and deliberately looser than `findValidGrant`: the CLI
    /// cannot compute its own fingerprint (the app derives it from the connection's peer), so
    /// asking it to match one would mean it never recognises its own approvals and prompts every
    /// single time. This is not a security boundary — the app checks properly before any value
    /// moves — it only decides whether to raise a window the person has already answered.
    public func hasLikelyValidGrant(credentialId: String, sessionId: String?) throws -> Bool {
        let file = try load()
        let now = Date()
        return file.grants.contains { grant in
            grant.credentialId == credentialId
                && grant.subjectFingerprint != nil   // unowned approvals no longer satisfy anyone
                && isValid(grant: grant, sessionId: sessionId, now: now)
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

    /// A credential's group ID changed: its terminal approvals follow it.
    public func moveGrants(from oldId: String, to newId: String) throws {
        guard oldId != newId else { return }
        try withFileLock { file in
            for index in file.grants.indices where file.grants[index].credentialId == oldId {
                file.grants[index].credentialId = newId
            }
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
