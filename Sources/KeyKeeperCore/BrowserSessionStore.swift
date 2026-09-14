import Foundation

public protocol BrowserSessionMarker: AnyObject {
    func wasCreated() throws -> Bool
    func markCreated() throws
}

/// Stores only an existence marker, never the session or site metadata.
public final class FileBrowserSessionMarker: BrowserSessionMarker {
    private let url: URL
    public init(directory: URL) { url = directory.appendingPathComponent("browser-store.created") }
    public func wasCreated() throws -> Bool {
        do {
            guard try Data(contentsOf: url) == Data([1]) else { throw BrowserSessionError.unavailable }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return false }
    }
    public func markCreated() throws {
        if try wasCreated() { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try Data([1]).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Dedicated encrypted item, with no dependency on the API-key blob or its metadata.
/// App is the sole process owner. Public replies expose summaries; only the browser
/// installation closure receives a snapshot in memory.
public final class BrowserSessionStore {
    private struct Record: Codable {
        let snapshot: BrowserSessionImport
        let createdAt: Date
        /// Absent in files written before 0.3.4. Absent means "ask every time", which is what
        /// those sessions have always done — a missing field must never quietly widen access.
        var security: SecurityLevel?
        var level: SecurityLevel { security ?? .strict }
    }
    /// What 0.3.4 development builds stored here before approvals moved to their own item.
    /// Kept only so migration can carry them over; nothing reads them for decisions.
    struct LegacyGrant: Codable {
        var id: String; var sessionId: String; var subjectFingerprint: String; var subjectDisplayName: String
        var duration: ApprovalDuration; var createdAt: Date; var lastUsedAt: Date?; var consumed: Bool
    }
    private struct Document: Codable {
        var version = 1
        var records: [String: Record] = [:]
        var grants: [LegacyGrant]? = nil
    }
    private let io: KeychainBlobIO
    private let marker: BrowserSessionMarker
    private let lock = NSRecursiveLock()
    private var observed = false

    public init(io: KeychainBlobIO, marker: BrowserSessionMarker) { self.io = io; self.marker = marker }

    public static func production() throws -> BrowserSessionStore {
        let name = try serviceName(environment: ProcessInfo.processInfo.environment)
        return .init(io: SecItemBlobIO(service: name), marker: FileBrowserSessionMarker(directory: KeyKeeperPaths.applicationSupportDirectory))
    }

    public static func serviceName(environment: [String: String]) throws -> String {
        let keys = ["KEYKEEPER_DATA_DIR", "KEYKEEPER_KEYCHAIN_SERVICE", "KEYKEEPER_TEST_SOCKET"]
        guard keys.contains(where: { environment[$0] != nil }) else { return "com.keykeeper.browser-sessions" }
        guard let service = environment["KEYKEEPER_KEYCHAIN_SERVICE"], service.hasPrefix("com.keykeeper.test."),
              let socket = environment["KEYKEEPER_TEST_SOCKET"], socket.hasPrefix("/tmp/keykeeper-test-"),
              IPCConstants.resolveSocketPath(environment: environment) == socket else { throw BrowserSessionError.unavailable }
        return service + ".browser-sessions"
    }

    public func list() throws -> [BrowserSessionSummary] {
        lock.lock(); defer { lock.unlock() }
        return try load().records.values.map { .init(snapshot: $0.snapshot, createdAt: $0.createdAt, security: $0.level) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
    }

    @discardableResult
    public func save(_ snapshot: BrowserSessionImport, now: Date = Date()) throws -> BrowserSessionSummary {
        lock.lock(); defer { lock.unlock() }
        try snapshot.validate(now: now)
        var document = try load()
        if let existing = document.records[snapshot.id] {
            guard existing.snapshot == snapshot else { throw BrowserSessionError.conflict }
            return .init(snapshot: existing.snapshot, createdAt: existing.createdAt, security: existing.level)
        }
        guard document.records.count < 32 else { throw BrowserSessionError.capacity }
        // New sessions start at the strictest setting. Widening is a decision the person makes.
        document.records[snapshot.id] = Record(snapshot: snapshot, createdAt: now, security: .strict)
        try write(document)
        return .init(snapshot: snapshot, createdAt: now, security: .strict)
    }

    public func withSnapshot<T>(id: String, now: Date = Date(), _ install: (BrowserSessionImport) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard let record = try load().records[id] else { throw BrowserSessionError.notFound }
        try record.snapshot.validate(now: now)
        return try install(record.snapshot)
    }

    /// Changing how a saved login may be used. Never touches the cookies themselves.
    public func setSecurity(id: String, to level: SecurityLevel) throws {
        lock.lock(); defer { lock.unlock() }
        var document = try load()
        guard var record = document.records[id] else { throw BrowserSessionError.notFound }
        record.security = level
        document.records[id] = record
        try write(document)
    }

    /// What the open path needs to know before deciding whether to ask.
    public func security(id: String) throws -> SecurityLevel {
        lock.lock(); defer { lock.unlock() }
        guard let record = try load().records[id] else { throw BrowserSessionError.notFound }
        return record.level
    }

    public func delete(id: String) throws {
        lock.lock(); defer { lock.unlock() }
        var document = try load()
        guard document.records.removeValue(forKey: id) != nil else { throw BrowserSessionError.notFound }
        try write(document)
    }

    // MARK: Migration

    /// The approvals an earlier build kept in this document, as JSON, and clears them. Nil when
    /// there are none. Called once by ApprovalMigration.
    public func takeLegacyGrants() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        var document = try load()
        guard let grants = document.grants, !grants.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(grants)
        document.grants = nil
        try write(document)
        return data
    }

    private func load() throws -> Document {
        guard let bytes = try io.readBlob() else {
            guard !observed, try !marker.wasCreated() else { throw BrowserSessionError.unavailable }
            return Document()
        }
        observed = true
        guard bytes.count <= 2_097_152 else { throw BrowserSessionError.unavailable }
        do {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, document.records.count <= 32 else { throw BrowserSessionError.unavailable }
            for (id, record) in document.records {
                guard id == record.snapshot.id else { throw BrowserSessionError.unavailable }
                try record.snapshot.validate(requireUnexpired: false)
            }
            // Preserve observation across process restart, including restored existing stores.
            try marker.markCreated()
            return document
        } catch { throw BrowserSessionError.unavailable }
    }

    private func write(_ document: Document) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(document)
        guard bytes.count <= 2_097_152 else { throw BrowserSessionError.capacity }
        // Fail closed after an uncertain first write; never silently recreate on retry.
        try marker.markCreated()
        try io.writeBlob(bytes, replacingExisting: observed)
        observed = true
    }
}
