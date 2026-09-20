import Foundation

public protocol BrowserImportProposalMarker: AnyObject, Sendable {
    func wasCreated() throws -> Bool
    func markCreated() throws
}

public final class FileBrowserImportProposalMarker: BrowserImportProposalMarker, @unchecked Sendable {
    private let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("browser-import-proposals.created")
    }

    public func wasCreated() throws -> Bool {
        do {
            guard try Data(contentsOf: url) == Data([1]) else {
                throw BrowserImportProposalStoreError.unavailable
            }
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return false
        }
    }

    public func markCreated() throws {
        if try wasCreated() { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data([1]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public enum BrowserImportProposalStoreError: Error, Equatable, LocalizedError {
    case unavailable
    case busy
    case notFound
    case conflict
    case capacity

    public var errorDescription: String? {
        switch self {
        case .unavailable: "KeyKeeper could not read its pending browser import from the Keychain."
        case .busy: "Another browser import is still awaiting a decision."
        case .notFound: "Browser import proposal not found."
        case .conflict: "Browser import proposal state changed unexpectedly."
        case .capacity: "Too many browser import results are retained."
        }
    }
}

/// The recoverable form of one browser paste. The candidate and all concurrency fingerprints
/// live only in the dedicated Keychain item. `finish` irreversibly removes them and retains only
/// the public snapshot so status remains useful after a decision.
public struct BrowserImportProposalRecord: Codable, Sendable, Equatable {
    public var snapshot: BrowserImportProposalSnapshot
    public var request: ClipboardSaveRequest?
    public var callerName: String?
    public var candidate: String?
    public var metadataFingerprint: Data?
    public var targetValueFingerprint: Data?
    public var createdAt: Date
    public var updatedAt: Date

    public init(snapshot: BrowserImportProposalSnapshot, request: ClipboardSaveRequest?,
                callerName: String?, candidate: String?, metadataFingerprint: Data?,
                targetValueFingerprint: Data?, createdAt: Date, updatedAt: Date) {
        self.snapshot = snapshot
        self.request = request
        self.callerName = callerName
        self.candidate = candidate
        self.metadataFingerprint = metadataFingerprint
        self.targetValueFingerprint = targetValueFingerprint
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    fileprivate func validated() throws -> BrowserImportProposalRecord {
        try BrowserImportProposalRequest(id: snapshot.id, action: .status).validate()
        guard snapshot.credentialId.utf8.count <= 128,
              snapshot.fieldName.utf8.count <= 128 else {
            throw BrowserImportProposalStoreError.unavailable
        }
        do {
            try ClipboardSaveRequest(credentialId: snapshot.credentialId,
                                     fieldName: snapshot.fieldName, create: true).validate()
        } catch {
            throw BrowserImportProposalStoreError.unavailable
        }
        if snapshot.state.isTerminal {
            guard request == nil, callerName == nil, candidate == nil,
                  metadataFingerprint == nil, targetValueFingerprint == nil,
                  snapshot.deadline == nil, snapshot.nextAction == nil else {
                throw BrowserImportProposalStoreError.unavailable
            }
            return self
        }
        guard [.pasteReceived, .approvalVisible, .committing].contains(snapshot.state),
              let request, let callerName, let candidate, let metadataFingerprint,
              snapshot.credentialId == request.credentialId,
              snapshot.fieldName == request.fieldName,
              snapshot.deadline != nil,
              !callerName.isEmpty, callerName.utf8.count <= 512,
              !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              candidate.utf8.count <= 65_536,
              metadataFingerprint.count == 32,
              targetValueFingerprint == nil || targetValueFingerprint?.count == 32 else {
            throw BrowserImportProposalStoreError.unavailable
        }
        do { try request.validate() }
        catch { throw BrowserImportProposalStoreError.unavailable }
        return self
    }
}

/// A bounded, single-active-proposal journal. It deliberately uses a separate Keychain item from
/// the credential vault: a crash cannot turn an unapproved paste into a credential, and normal
/// credential reads never need to decode transient proposal state.
public final class BrowserImportProposalStore: @unchecked Sendable {
    private struct Document: Codable {
        var version = 1
        var records: [String: BrowserImportProposalRecord] = [:]
    }

    public static let maximumRecords = 16
    private let io: KeychainBlobIO
    private let marker: BrowserImportProposalMarker
    private let lock = NSLock()
    private var observed = false

    public init(io: KeychainBlobIO, marker: BrowserImportProposalMarker) {
        self.io = io
        self.marker = marker
    }

    public static func serviceName(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try SecItemBlobIO.serviceName(environment: environment) + ".browser-import-proposals"
    }

    public static func production() throws -> BrowserImportProposalStore {
        .init(
            io: SecItemBlobIO(service: try serviceName()),
            marker: FileBrowserImportProposalMarker(directory: KeyKeeperPaths.applicationSupportDirectory)
        )
    }

    public func records() throws -> [BrowserImportProposalRecord] {
        try lock.withLock {
            try load().records.values.sorted {
                $0.updatedAt == $1.updatedAt ? $0.snapshot.id < $1.snapshot.id : $0.updatedAt < $1.updatedAt
            }
        }
    }

    public func record(id: String) throws -> BrowserImportProposalRecord? {
        try lock.withLock { try load().records[id] }
    }

    public func stage(_ record: BrowserImportProposalRecord) throws {
        try lock.withLock {
            let record = try record.validated()
            guard !record.snapshot.state.isTerminal else { throw BrowserImportProposalStoreError.conflict }
            var document = try load()
            if let active = document.records.values.first(where: { !$0.snapshot.state.isTerminal }),
               active.snapshot.id != record.snapshot.id {
                throw BrowserImportProposalStoreError.busy
            }
            if let existing = document.records[record.snapshot.id] {
                guard existing == record else { throw BrowserImportProposalStoreError.conflict }
                return
            }
            pruneTerminalRecords(&document, keeping: Self.maximumRecords - 1)
            guard document.records.count < Self.maximumRecords else {
                throw BrowserImportProposalStoreError.capacity
            }
            document.records[record.snapshot.id] = record
            try write(document)
        }
    }

    public func update(id: String, snapshot: BrowserImportProposalSnapshot, now: Date = Date()) throws {
        try lock.withLock {
            var document = try load()
            guard var record = document.records[id], !record.snapshot.state.isTerminal,
                  !snapshot.state.isTerminal,
                  snapshot.id == id,
                  snapshot.credentialId == record.snapshot.credentialId,
                  snapshot.fieldName == record.snapshot.fieldName else {
                throw BrowserImportProposalStoreError.conflict
            }
            record.snapshot = snapshot
            record.updatedAt = now
            document.records[id] = try record.validated()
            try write(document)
        }
    }

    public func finish(id: String, snapshot: BrowserImportProposalSnapshot, now: Date = Date()) throws {
        try lock.withLock {
            var document = try load()
            guard let existing = document.records[id], snapshot.state.isTerminal,
                  snapshot.id == id,
                  snapshot.credentialId == existing.snapshot.credentialId,
                  snapshot.fieldName == existing.snapshot.fieldName else {
                throw BrowserImportProposalStoreError.conflict
            }
            let terminal = BrowserImportProposalRecord(
                snapshot: snapshot, request: nil, callerName: nil, candidate: nil,
                metadataFingerprint: nil, targetValueFingerprint: nil,
                createdAt: existing.createdAt, updatedAt: now
            )
            document.records[id] = try terminal.validated()
            pruneTerminalRecords(&document, keeping: Self.maximumRecords)
            try write(document)
        }
    }

    private func pruneTerminalRecords(_ document: inout Document, keeping limit: Int) {
        let terminals = document.records.values.filter(\.snapshot.state.isTerminal).sorted {
            $0.updatedAt == $1.updatedAt ? $0.snapshot.id < $1.snapshot.id : $0.updatedAt > $1.updatedAt
        }
        for record in terminals.dropFirst(limit) { document.records.removeValue(forKey: record.snapshot.id) }
    }

    private func load() throws -> Document {
        guard let bytes = try io.readBlob() else {
            guard !observed, try !marker.wasCreated() else {
                throw BrowserImportProposalStoreError.unavailable
            }
            return Document()
        }
        observed = true
        guard bytes.count <= 1_200_000 else { throw BrowserImportProposalStoreError.unavailable }
        do {
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, document.records.count <= Self.maximumRecords else {
                throw BrowserImportProposalStoreError.unavailable
            }
            for (id, record) in document.records {
                guard id == record.snapshot.id else { throw BrowserImportProposalStoreError.unavailable }
                _ = try record.validated()
            }
            guard document.records.values.filter({ !$0.snapshot.state.isTerminal }).count <= 1 else {
                throw BrowserImportProposalStoreError.unavailable
            }
            try marker.markCreated()
            return document
        } catch let error as BrowserImportProposalStoreError {
            throw error
        } catch {
            throw BrowserImportProposalStoreError.unavailable
        }
    }

    private func write(_ document: Document) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes: Data
        do { bytes = try encoder.encode(document) }
        catch { throw BrowserImportProposalStoreError.unavailable }
        guard bytes.count <= 1_200_000 else { throw BrowserImportProposalStoreError.capacity }
        do {
            try marker.markCreated()
            try io.writeBlob(bytes, replacingExisting: observed)
            observed = true
        } catch let error as BrowserImportProposalStoreError {
            throw error
        } catch {
            throw BrowserImportProposalStoreError.unavailable
        }
    }
}
