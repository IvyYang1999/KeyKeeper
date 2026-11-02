import Foundation
import CryptoKit
import Darwin

public protocol LocalVaultJournalMarker: AnyObject, Sendable {
    func wasCreated() throws -> Bool
    func markCreated() throws
}

/// No secret material is stored here. An initialized vault must not mistake a
/// missing journal item for first use. The durable Keychain document holds images.
public final class FileLocalVaultJournalMarker: LocalVaultJournalMarker, @unchecked Sendable {
    private let url: URL
    public init(url: URL) { self.url = url }
    public func wasCreated() throws -> Bool {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return false }
            throw LocalVaultCommitError.unavailable
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, info.st_size == 1 else {
            throw LocalVaultCommitError.malformed
        }
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) == 1, byte == 1 else { throw LocalVaultCommitError.malformed }
        return true
    }
    public func markCreated() throws {
        if try wasCreated() { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw LocalVaultCommitError.unavailable }
        defer { close(fd) }
        var byte: UInt8 = 1
        guard write(fd, &byte, 1) == 1, fsync(fd) == 0 else { throw LocalVaultCommitError.unavailable }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw LocalVaultCommitError.unavailable }
        defer { close(parent) }
        guard fsync(parent) == 0 else { throw LocalVaultCommitError.unavailable }
    }
}

public final class LocalVaultJournal {
    public static let initialGeneration = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    public static let maximumBytes = 16 * 1024 * 1024
    let io: KeychainBlobIO
    let marker: any LocalVaultJournalMarker
    public let namespace: String
    struct Document: Codable, Equatable {
        var version = 1
        var namespace: String
        var generation: UUID
        var lastDigest: String?
        var pending: LocalVaultCommitPlan?
    }

    public init(io: KeychainBlobIO, marker: any LocalVaultJournalMarker, namespace: String) {
        self.io = io; self.marker = marker; self.namespace = namespace
    }
    public static func production() throws -> LocalVaultJournal {
        let service = try SecItemBlobIO.serviceName(environment: ProcessInfo.processInfo.environment)
        let directory = KeyKeeperPaths.applicationSupportDirectory
        return LocalVaultJournal(io: SecItemBlobIO(service: service + ".local-sync-journal"),
            marker: FileLocalVaultJournalMarker(url: directory.appendingPathComponent("local-sync-journal.created")),
            namespace: Self.namespace(service: service, directory: directory))
    }
    public static func namespace(service: String, directory: URL) -> String {
        let binding = service + "\u{0}" + directory.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(binding.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func requireReady() throws {
        let doc = try load()
        guard doc?.pending == nil else { throw LocalVaultCommitError.pending }
    }
    /// Once initialized, legacy serving never becomes safe again, including a virgin
    /// ready record left by an interrupted first commit. Missing/denied state is an error.
    public func requiresBoundRequests() throws -> Bool { try load() != nil }
    public func generation() throws -> UUID {
        let doc = try load()
        guard doc?.pending == nil else { throw LocalVaultCommitError.pending }
        return doc?.generation ?? Self.initialGeneration
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    func load(allowMissingMarker: Bool = false) throws -> Document? {
        let created = try marker.wasCreated()
        guard let bytes = try io.readBlobWithoutInteraction() else {
            guard !created else { throw LocalVaultCommitError.unavailable }
            return nil
        }
        guard bytes.count <= Self.maximumBytes else { throw LocalVaultCommitError.malformed }
        let doc: Document
        do { doc = try JSONDecoder().decode(Document.self, from: bytes) }
        catch { throw LocalVaultCommitError.malformed }
        guard doc.version == 1, doc.namespace == namespace, try Self.encode(doc) == bytes else {
            throw LocalVaultCommitError.malformed
        }
        guard (doc.generation == Self.initialGeneration && doc.lastDigest == nil)
            || (doc.generation != Self.initialGeneration && Self.validDigest(doc.lastDigest)) else {
            throw LocalVaultCommitError.malformed
        }
        if let pending = doc.pending {
            try validateShape(pending)
            guard pending.expectedGeneration == doc.generation else { throw LocalVaultCommitError.malformed }
        }
        guard created || allowMissingMarker else { throw LocalVaultCommitError.unavailable }
        return doc
    }

    func validateShape(_ plan: LocalVaultCommitPlan) throws {
        guard !namespace.isEmpty, namespace.utf8.count <= 512, plan.namespace == namespace,
              plan.id != Self.initialGeneration, plan.id != plan.expectedGeneration,
              plan.after.metadata != nil, plan.after.values != nil,
              [plan.before.metadata, plan.before.values, plan.after.metadata, plan.after.values]
                .allSatisfy({ ($0?.count ?? 0) <= Self.maximumBytes }),
              plan.changedCredentialIDs.count <= 4096,
              plan.changedCredentialIDs == Array(Set(plan.changedCredentialIDs)).sorted(),
              plan.changedCredentialIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }),
              try Self.encode(plan).count <= Self.maximumBytes - 1024 else {
            throw LocalVaultCommitError.invalidPlan
        }
    }

    func digest(_ plan: LocalVaultCommitPlan) throws -> String {
        SHA256.hash(data: try Self.encode(plan)).map { String(format: "%02x", $0) }.joined()
    }

    private static func validDigest(_ digest: String?) -> Bool {
        guard let digest, digest.utf8.count == 64 else { return false }
        return digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Fresh initialization is ordered journal → marker → pending, so a crash can
    /// never leave existing data changed with no write-ahead evidence.
    func prepare(_ plan: LocalVaultCommitPlan) throws {
        var current = try load()
        if current == nil {
            let initial = Document(namespace: namespace, generation: Self.initialGeneration)
            try store(initial, replacing: nil)
            try persistMarker()
            current = initial
        }
        guard var pending = current, pending.pending == nil,
              pending.generation == plan.expectedGeneration else { throw LocalVaultCommitError.staleGeneration }
        pending.pending = plan
        try store(pending, replacing: current)
    }

    func finish(_ plan: LocalVaultCommitPlan) throws {
        guard let current = try load(), current.pending == plan else { throw LocalVaultCommitError.conflict }
        let complete = Document(namespace: namespace, generation: plan.id, lastDigest: try digest(plan))
        try store(complete, replacing: current)
    }

    func recoverDocument() throws -> Document? {
        let doc = try load(allowMissingMarker: true)
        if doc != nil, !(try marker.wasCreated()) {
            // Only a virgin ready record can precede marker creation.
            guard doc?.generation == Self.initialGeneration, doc?.pending == nil else {
                throw LocalVaultCommitError.unavailable
            }
            try persistMarker()
        }
        return doc
    }

    private func persistMarker() throws {
        do { try marker.markCreated() } catch { /* resolve an ambiguous write by exact readback */ }
        guard try marker.wasCreated() else { throw LocalVaultCommitError.unavailable }
    }

    private func store(_ document: Document, replacing expected: Document?) throws {
        let desired = try Self.encode(document)
        guard desired.count <= Self.maximumBytes else { throw LocalVaultCommitError.invalidPlan }
        let expectedBytes = try expected.map(Self.encode)
        guard try io.readBlobWithoutInteraction() == expectedBytes else { throw LocalVaultCommitError.conflict }
        do { try io.writeBlob(desired, replacingExisting: expected != nil) }
        catch { /* SecItem may have committed despite returning an error; do not retry. */ }
        guard let observed = try io.readBlobWithoutInteraction(), observed == desired else {
            throw LocalVaultCommitError.unavailable
        }
    }
}
