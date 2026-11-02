import Foundation
import CryptoKit
import Darwin

public protocol IdentityMigrationDestination: AnyObject {
    func readItem(_ item: IdentityMigrationItem) throws -> Data?
    func createItem(_ item: IdentityMigrationItem, data: Data) throws
    func readFile(_ name: String) throws -> Data?
    func createFile(_ name: String, data: Data) throws
    func readJournal() throws -> Data?
    func writeJournal(_ data: Data, replacingExisting: Bool) throws
}

/// A create-only forward journal lives in the new identity's non-sync DP Keychain. It retains
/// the approved image until all target items/files read back, then retains only a ready receipt.
public final class IdentityMigrationCoordinator {
    private struct Journal: Codable {
        var version = 1
        var sourceDigest: String
        var prepared: IdentityMigrationPrepared?
        var summary: IdentityMigrationSummary
        var requiredItems: [IdentityMigrationItem]
    }
    private let destination: any IdentityMigrationDestination
    private let lock = NSRecursiveLock()
    public init(destination: any IdentityMigrationDestination) { self.destination = destination }
    public static func production() -> IdentityMigrationCoordinator {
        .init(destination: IdentityMigrationFileDestination(directory: StorageIdentity.current.directory))
    }

    public func status() throws -> IdentityMigrationStatus {
        try lock.withLock {
            guard let journal = try journal() else {
                try requireEmpty()
                return .required
            }
            if journal.prepared != nil { return .pending }
            try verifyReady(journal)
            return .ready
        }
    }

    @discardableResult
    public func migrate(source: IdentityMigrationSource, allowUnsignedMetadata: Bool = false) throws -> IdentityMigrationSummary {
        try lock.withLock {
            if let prior = try journal() {
                if prior.prepared == nil { try verifyReady(prior); return prior.summary }
                guard prior.sourceDigest == Self.digest(try source.encoded()) else { throw IdentityMigrationError.sourceChanged }
                return try finish(prior)
            }
            try requireEmpty()
            let prepared = try source.prepared(allowUnsignedMetadata: allowUnsignedMetadata)
            let journal = Journal(sourceDigest: Self.digest(try source.encoded()), prepared: prepared,
                                  summary: prepared.summary, requiredItems: prepared.items.keys.sorted { $0.rawValue < $1.rawValue })
            let bytes = try IdentityMigrationCodec.encode(journal)
            guard bytes.count <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.malformed }
            do { try destination.writeJournal(bytes, replacingExisting: false) }
            catch { guard try destination.readJournal() == bytes else { throw IdentityMigrationError.unavailable } }
            guard try destination.readJournal() == bytes else { throw IdentityMigrationError.unavailable }
            return try finish(journal)
        }
    }

    /// Only a previously confirmed, encrypted pending image can recover without another import.
    @discardableResult
    public func recover() throws -> IdentityMigrationSummary? {
        try lock.withLock {
            guard let journal = try journal() else { return nil }
            if journal.prepared == nil { try verifyReady(journal); return journal.summary }
            return try finish(journal)
        }
    }

    public func applyPreferences(to defaults: UserDefaults = .standard) throws {
        try lock.withLock {
            guard try status() == .ready else { throw IdentityMigrationError.unavailable }
            if let bytes = try destination.readFile("migration-preferences.json") {
                try IdentityMigrationPreferences.apply(bytes, to: defaults)
            }
        }
    }

    private func journal() throws -> Journal? {
        guard let bytes = try destination.readJournal() else { return nil }
        let journal = try IdentityMigrationCodec.decode(Journal.self, from: bytes)
        guard journal.version == 1, journal.sourceDigest.count == 64,
              journal.sourceDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              journal.summary.credentialCount >= 0, journal.summary.missingValueCount >= 0,
              journal.summary.browserSessionCount >= 0,
              journal.requiredItems == Array(Set(journal.requiredItems)).sorted(by: { $0.rawValue < $1.rawValue }),
              Set(journal.requiredItems).isSuperset(of: [.values, .metadataKey, .approvals]) else {
            throw IdentityMigrationError.malformed
        }
        if let prepared = journal.prepared {
            guard prepared.summary == journal.summary, Set(prepared.items.keys) == Set(journal.requiredItems),
                  Set(prepared.files.keys).isSubset(of: Self.fileNames), prepared.files["meta.json"] != nil,
                  prepared.items[.metadataKey]?.count == 32 else { throw IdentityMigrationError.malformed }
        }
        return journal
    }

    private func requireEmpty() throws {
        for item in IdentityMigrationItem.allCases where try destination.readItem(item) != nil {
            throw IdentityMigrationError.destinationConflict
        }
        for name in Self.fileNames where try destination.readFile(name) != nil {
            throw IdentityMigrationError.destinationConflict
        }
    }

    private func finish(_ journal: Journal) throws -> IdentityMigrationSummary {
        guard let prepared = journal.prepared else { throw IdentityMigrationError.malformed }
        for item in prepared.items.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let expected = prepared.items[item]!
            try ensure(expected, read: { try destination.readItem(item) }, create: { try destination.createItem(item, data: expected) })
        }
        for name in prepared.files.keys.sorted() {
            let expected = prepared.files[name]!
            try ensure(expected, read: { try destination.readFile(name) }, create: { try destination.createFile(name, data: expected) })
        }
        var complete = journal
        complete.prepared = nil
        try verifyReady(complete)
        let bytes = try IdentityMigrationCodec.encode(complete)
        do { try destination.writeJournal(bytes, replacingExisting: true) }
        catch { guard try destination.readJournal() == bytes else { throw IdentityMigrationError.unavailable } }
        guard try destination.readJournal() == bytes else { throw IdentityMigrationError.unavailable }
        return journal.summary
    }

    private func ensure(_ expected: Data, read: () throws -> Data?, create: () throws -> Void) throws {
        if let current = try read() {
            guard current == expected else { throw IdentityMigrationError.destinationConflict }
            return
        }
        do { try create() }
        catch { guard try read() == expected else { throw IdentityMigrationError.unavailable } }
        guard try read() == expected else { throw IdentityMigrationError.unavailable }
    }

    private func verifyReady(_ journal: Journal) throws {
        for item in journal.requiredItems where try destination.readItem(item) == nil { throw IdentityMigrationError.unavailable }
        guard let key = try destination.readItem(.metadataKey), key.count == 32,
              let bytes = try destination.readFile("meta.json"),
              let values = try destination.readItem(.values), let approvals = try destination.readItem(.approvals) else {
            throw IdentityMigrationError.unavailable
        }
        let meta = try IdentityMigrationCodec.decode(MetaFile.self, from: bytes)
        let blob = try IdentityMigrationCodec.decode(KeychainBlobStore.Blob.self, from: values)
        let grants = try IdentityMigrationCodec.decode(ApprovalDocument.self, from: approvals, datesISO8601: true)
        guard meta.version == 1, meta.storeInitialized == true, MetaIntegrity.verify(meta, key: key) == .intact,
              blob.version == 1, grants.version == 2 else { throw IdentityMigrationError.malformed }
        // Missing fields that existed before migration stay missing. They block cloud enrollment,
        // not healthy local editing. The complete raw blob also retains unreferenced old values.
    }

    static let fileNames: Set<String> = ["meta.json", "metadata-changes.json", "migration-preferences.json",
                                         "browser-store.created", "browser-import-proposals.created"]
    private static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

/// Fixed new-identity destination; no configurable production source or ACL mutation exists.
public final class IdentityMigrationFileDestination: IdentityMigrationDestination {
    private let directory: URL
    private let io: (IdentityMigrationItem) -> any KeychainBlobIO
    private let journalIO: any KeychainBlobIO
    public init(directory: URL) {
        self.directory = directory
        self.io = { SecItemBlobIO(service: StorageIdentity.current.servicePrefix + $0.suffix, identity: .current) }
        self.journalIO = SecItemBlobIO(service: "dev.keykeeper.identity-migration", identity: .current)
    }
    init(directory: URL, io: @escaping (IdentityMigrationItem) -> any KeychainBlobIO, journalIO: any KeychainBlobIO) {
        self.directory = directory; self.io = io; self.journalIO = journalIO
    }
    public func readItem(_ item: IdentityMigrationItem) throws -> Data? { try io(item).readBlobWithoutInteraction() }
    public func createItem(_ item: IdentityMigrationItem, data: Data) throws { try io(item).writeBlob(data, replacingExisting: false) }
    public func readJournal() throws -> Data? { try journalIO.readBlobWithoutInteraction() }
    public func writeJournal(_ data: Data, replacingExisting: Bool) throws { try journalIO.writeBlob(data, replacingExisting: replacingExisting) }
    public func readFile(_ name: String) throws -> Data? {
        guard IdentityMigrationCoordinator.fileNames.contains(name) else { throw IdentityMigrationError.malformed }
        try validateDirectory(create: false)
        return try IdentityMigrationFiles.read(directory.appendingPathComponent(name))
    }
    public func createFile(_ name: String, data: Data) throws {
        guard IdentityMigrationCoordinator.fileNames.contains(name) else { throw IdentityMigrationError.malformed }
        try validateDirectory(create: true)
        try IdentityMigrationFiles.create(data, at: directory.appendingPathComponent(name))
    }
    private func validateDirectory(create: Bool) throws {
        if create { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, !create else { throw IdentityMigrationError.unavailable }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw IdentityMigrationError.unavailable }
    }
}

enum IdentityMigrationFiles {
    static func read(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw IdentityMigrationError.unavailable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_size >= 0, info.st_size <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.unavailable }
        let bytes = try handle.read(upToCount: IdentityMigrationSource.maximumBytes + 1) ?? Data()
        guard bytes.count <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.malformed }
        return bytes
    }
    static func create(_ bytes: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".identity-stage-" + UUID().uuidString)
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw IdentityMigrationError.unavailable }
        defer { close(fd); _ = unlink(temporary.path) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard amount > 0 else { throw IdentityMigrationError.unavailable }
                offset += amount
            }
        }
        guard fsync(fd) == 0 else { throw IdentityMigrationError.unavailable }
        // link is an atomic create-only publication: a crash cannot expose a partial target.
        guard link(temporary.path, url.path) == 0 else { throw IdentityMigrationError.destinationConflict }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw IdentityMigrationError.unavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw IdentityMigrationError.unavailable }
    }
}
