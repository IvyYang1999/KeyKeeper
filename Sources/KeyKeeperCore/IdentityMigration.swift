import Foundation
import CryptoKit
import CoreFoundation

public enum IdentityMigrationError: String, Error, LocalizedError {
    case unavailable, malformed, unsignedMetadata, activeImport, sourceChanged, destinationConflict, legacyRunning, identity
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Local migration could not read its required state. Existing data was kept."
        case .malformed: return "The old data could not be verified. No new vault was activated."
        case .unsignedMetadata: return "The old metadata is unsigned. Confirm its contents before migration."
        case .activeImport: return "Finish or cancel the pending import in the old KeyKeeper first."
        case .sourceChanged: return "The old data changed during migration. No new vault was activated."
        case .destinationConflict: return "The destination contains different data. It was not overwritten."
        case .legacyRunning: return "Quit the old KeyKeeper before migrating its local data."
        case .identity: return "The migration helper or application signature is not the expected identity."
        }
    }
}

/// Secret-bearing, local pipe only. It is deliberately not a cloud snapshot: missing fields and
/// orphan values must survive an identity change even though they cannot join cloud sync yet.
public struct IdentityMigrationSource: Codable, Sendable, CustomStringConvertible, CustomReflectable {
    public var version: Int = 1
    public var metadata: Data?
    public var values: Data?
    public var integrityKey: Data?
    public var approvals: Data?
    public var browserSessions: Data?
    public var proposals: Data?
    public var metadataHistory: Data?
    public var preferences: Data?
    public var browserMarker: Bool
    public var proposalMarker: Bool
    public init(metadata: Data? = nil, values: Data? = nil, integrityKey: Data? = nil,
                approvals: Data? = nil, browserSessions: Data? = nil, proposals: Data? = nil,
                metadataHistory: Data? = nil, preferences: Data? = nil,
                browserMarker: Bool = false, proposalMarker: Bool = false) {
        self.metadata = metadata; self.values = values; self.integrityKey = integrityKey
        self.approvals = approvals; self.browserSessions = browserSessions; self.proposals = proposals
        self.metadataHistory = metadataHistory; self.preferences = preferences
        self.browserMarker = browserMarker; self.proposalMarker = proposalMarker
    }
    public var description: String { "IdentityMigrationSource([redacted])" }
    public var customMirror: Mirror { Mirror(self, children: ["contents": "[redacted]"]) }
    public static let maximumBytes = 32 * 1024 * 1024
    public func encoded() throws -> Data { try IdentityMigrationCodec.encode(self) }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw IdentityMigrationError.malformed }
        return try IdentityMigrationCodec.decode(Self.self, from: data)
    }

    func prepared(allowUnsignedMetadata: Bool) throws -> IdentityMigrationPrepared {
        guard version == 1, try encoded().count <= Self.maximumBytes else { throw IdentityMigrationError.malformed }
        var meta: MetaFile
        if let metadata {
            meta = try IdentityMigrationCodec.decode(MetaFile.self, from: metadata)
            guard meta.version == 1,
                  !meta.credentials.values.contains(where: { $0.fields.values.contains(where: { $0.secret && $0.value != nil }) })
            else { throw IdentityMigrationError.malformed }
            if let integrityKey {
                guard integrityKey.count == 32, MetaIntegrity.verify(meta, key: integrityKey) == .intact
                else { throw IdentityMigrationError.malformed }
            } else {
                guard meta.integrity == nil else { throw IdentityMigrationError.malformed }
                guard allowUnsignedMetadata else { throw IdentityMigrationError.unsignedMetadata }
            }
        } else {
            guard integrityKey == nil else { throw IdentityMigrationError.malformed }
            meta = MetaFile()
        }
        let blob: KeychainBlobStore.Blob
        if let values {
            blob = try IdentityMigrationCodec.decode(KeychainBlobStore.Blob.self, from: values)
            guard blob.version == 1, metadata != nil || blob.credentials.isEmpty else { throw IdentityMigrationError.malformed }
        } else {
            guard meta.storeInitialized != true,
                  !meta.credentials.values.contains(where: { $0.fields.values.contains(where: { $0.secret }) })
            else { throw IdentityMigrationError.malformed }
            blob = .empty
        }
        var approvals: ApprovalDocument = try self.approvals.map {
            try IdentityMigrationCodec.decode(ApprovalDocument.self, from: $0, datesISO8601: true)
        } ?? .init()
        guard approvals.version == 2, approvals.auditEvents.count <= ApprovalStore.maxAuditEvents else {
            throw IdentityMigrationError.malformed
        }
        approvals.approvals = []
        approvals.mode = .enforced
        var items: [IdentityMigrationItem: Data] = [
            .values: try values ?? IdentityMigrationCodec.encode(blob),
            .approvals: try IdentityMigrationCodec.encode(approvals, datesISO8601: true),
        ]
        if let browserSessions {
            var browser = try IdentityMigrationCodec.decode(MigrationBrowserDocument.self, from: browserSessions)
            guard browser.version == 1, browser.records.count <= 32 else { throw IdentityMigrationError.malformed }
            for (id, record) in browser.records {
                guard id == record.snapshot.id else { throw IdentityMigrationError.malformed }
                try record.snapshot.validate(requireUnexpired: false)
            }
            browser.grants = nil // Old in-document grants must not be reimported by LaunchMaintenance.
            items[.browserSessions] = try IdentityMigrationCodec.encode(browser)
        } else if browserMarker { throw IdentityMigrationError.malformed }
        if let proposals {
            let document = try IdentityMigrationCodec.decode(MigrationProposalDocument.self, from: proposals)
            guard document.version == 1, document.records.count <= BrowserImportProposalStore.maximumRecords,
                  document.records.allSatisfy({ $0.key == $0.value.snapshot.id }) else { throw IdentityMigrationError.malformed }
            guard document.records.values.allSatisfy({ $0.snapshot.state.isTerminal }) else { throw IdentityMigrationError.activeImport }
            guard document.records.values.allSatisfy({ $0.candidate == nil && $0.request == nil && $0.callerName == nil
                && $0.metadataFingerprint == nil && $0.targetValueFingerprint == nil
                && $0.snapshot.deadline == nil && $0.snapshot.nextAction == nil }) else { throw IdentityMigrationError.malformed }
            for record in document.records.values {
                try BrowserImportProposalRequest(id: record.snapshot.id, action: .status).validate()
                try ClipboardSaveRequest(credentialId: record.snapshot.credentialId, fieldName: record.snapshot.fieldName, create: true).validate()
            }
            items[.proposals] = proposals
        } else if proposalMarker { throw IdentityMigrationError.malformed }
        var files: [String: Data] = [:]
        if let metadataHistory {
            let records = try IdentityMigrationCodec.decode([MetadataChangeRecord].self, from: metadataHistory, datesISO8601: true)
            guard records.count <= 200 else { throw IdentityMigrationError.malformed }
            files["metadata-changes.json"] = metadataHistory
        }
        if let preferences {
            _ = try IdentityMigrationPreferences.decode(preferences)
            files["migration-preferences.json"] = preferences
        }
        let newKey = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        meta.storeInitialized = true
        meta.integrity = try MetaIntegrity.mac(for: meta, key: newKey)
        items[.metadataKey] = newKey
        files["meta.json"] = try IdentityMigrationCodec.encode(meta)
        if items[.browserSessions] != nil { files["browser-store.created"] = Data([1]) }
        if items[.proposals] != nil { files["browser-import-proposals.created"] = Data([1]) }
        let missing = meta.credentials.reduce(0) { count, entry in
            count + entry.value.fields.filter { $0.value.secret && blob.credentials[entry.key]?[$0.key] == nil }.count
        }
        return .init(items: items, files: files,
            summary: .init(credentialCount: meta.credentials.count, missingValueCount: missing,
                           browserSessionCount: try browserSessions.map {
                               try IdentityMigrationCodec.decode(MigrationBrowserDocument.self, from: $0).records.count
                           } ?? 0))
    }
}

public struct IdentityMigrationSummary: Codable, Sendable, Equatable {
    public var credentialCount: Int
    public var missingValueCount: Int
    public var browserSessionCount: Int
    public var transferredGrants: Int { 0 }
}

public enum IdentityMigrationStatus: Sendable, Equatable { case required, pending, ready }
public enum IdentityMigrationItem: String, Codable, CaseIterable, Hashable, Sendable {
    case values, metadataKey, approvals, browserSessions, proposals
    var suffix: String {
        switch self {
        case .values: "credentials"
        case .metadataKey: "metadata-mac"
        case .approvals: "credentials.approvals"
        case .browserSessions: "browser-sessions"
        case .proposals: "credentials.browser-import-proposals"
        }
    }
}
struct IdentityMigrationPrepared: Codable {
    var items: [IdentityMigrationItem: Data]
    var files: [String: Data]
    var summary: IdentityMigrationSummary
    private enum CodingKeys: String, CodingKey { case items, files, summary }
    init(items: [IdentityMigrationItem: Data], files: [String: Data], summary: IdentityMigrationSummary) {
        self.items = items; self.files = files; self.summary = summary
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let strings = try container.decode([String: Data].self, forKey: .items)
        items = [:]
        for (key, value) in strings {
            guard let item = IdentityMigrationItem(rawValue: key) else { throw IdentityMigrationError.malformed }
            items[item] = value
        }
        files = try container.decode([String: Data].self, forKey: .files)
        summary = try container.decode(IdentityMigrationSummary.self, forKey: .summary)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Dictionary(uniqueKeysWithValues: items.map { ($0.key.rawValue, $0.value) }), forKey: .items)
        try container.encode(files, forKey: .files)
        try container.encode(summary, forKey: .summary)
    }
}

enum IdentityMigrationCodec {
    static func encode<T: Encodable>(_ object: T, datesISO8601: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if datesISO8601 { encoder.dateEncodingStrategy = .iso8601 }
        return try encoder.encode(object)
    }
    static func decode<T: Codable>(_ type: T.Type, from bytes: Data, datesISO8601: Bool = false) throws -> T {
        guard bytes.count <= IdentityMigrationSource.maximumBytes else { throw IdentityMigrationError.malformed }
        do {
            let decoder = JSONDecoder(); if datesISO8601 { decoder.dateDecodingStrategy = .iso8601 }
            let object = try decoder.decode(type, from: bytes)
            let input = try JSONSerialization.jsonObject(with: bytes) as AnyObject
            let output = try JSONSerialization.jsonObject(with: encode(object, datesISO8601: datesISO8601)) as AnyObject
            guard input.isEqual(output) else { throw IdentityMigrationError.malformed }
            return object
        } catch { throw IdentityMigrationError.malformed }
    }
}

private struct MigrationBrowserRecord: Codable {
    var snapshot: BrowserSessionImport
    var createdAt: Date
    var security: SecurityLevel?
}
private struct MigrationBrowserGrant: Codable {
    var id: String; var sessionId: String; var subjectFingerprint: String; var subjectDisplayName: String
    var duration: ApprovalDuration; var createdAt: Date; var lastUsedAt: Date?; var consumed: Bool
}
private struct MigrationBrowserDocument: Codable {
    var version: Int
    var records: [String: MigrationBrowserRecord]
    var grants: [MigrationBrowserGrant]?
}
private struct MigrationProposalDocument: Codable {
    var version: Int
    var records: [String: BrowserImportProposalRecord]
}

public enum IdentityMigrationPreferences {
    private static let booleanKeys: Set<String> = ["setupComplete", "approvalSoundEnabled", "missedApprovalRecordError",
                                                   "SUEnableAutomaticChecks", "SUAutomaticallyUpdate"]
    public static func capture(from defaults: UserDefaults) throws -> Data {
        var selected: [String: Any] = [:]
        for key in booleanKeys {
            if let value = defaults.object(forKey: key) as? NSNumber {
                guard CFGetTypeID(value) == CFBooleanGetTypeID() else { throw IdentityMigrationError.malformed }
                selected[key] = value.boolValue
            }
        }
        if let language = defaults.string(forKey: "interfaceLanguage"), ["system", "en", "zh-Hans"].contains(language) {
            selected["interfaceLanguage"] = language
        }
        for key in ["lastSeenMetadataChange", "dismissedMissedApprovalIDs"] {
            if let value = defaults.object(forKey: key) { selected[key] = value }
        }
        let bytes = try JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys])
        _ = try decode(bytes)
        return bytes
    }
    static func decode(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= 65_536, let values = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(values.keys).isSubset(of: booleanKeys.union(["interfaceLanguage", "lastSeenMetadataChange", "dismissedMissedApprovalIDs"])) else { throw IdentityMigrationError.malformed }
        for (key, value) in values {
            if key == "interfaceLanguage" {
                guard let language = value as? String, ["system", "en", "zh-Hans"].contains(language) else { throw IdentityMigrationError.malformed }
            } else if key == "lastSeenMetadataChange" {
                guard let id = value as? String, id.utf8.count <= 128 else { throw IdentityMigrationError.malformed }
            } else if key == "dismissedMissedApprovalIDs" {
                guard let ids = value as? [String], ids.count <= 500, ids.allSatisfy({ $0.utf8.count <= 128 }) else { throw IdentityMigrationError.malformed }
            } else {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw IdentityMigrationError.malformed }
            }
        }
        return values
    }
    public static func apply(_ bytes: Data, to defaults: UserDefaults) throws {
        guard !defaults.bool(forKey: "identityMigrationPreferencesApplied") else { return }
        for (key, value) in try decode(bytes) where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        defaults.set(true, forKey: "identityMigrationPreferencesApplied")
    }
}
