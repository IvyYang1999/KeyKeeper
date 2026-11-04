import Foundation

/// Transport-independent secret-bearing data. Never log, expose over IPC, or write to a plain
/// file. This is deliberately NOT MetaFile: local integrity keys and grants are not portable.
public struct CloudCredentialBundle: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var metadata: Credential
    public var secrets: [String: String]
    /// Explicit absence inside an otherwise readable store; never an instruction to erase a value.
    public var missingSecretFields: [String]

    public init(metadata: Credential, secrets: [String: String], missingSecretFields: [String] = []) {
        self.metadata = metadata
        self.secrets = secrets
        self.missingSecretFields = missingSecretFields
    }

    private enum CodingKeys: String, CodingKey { case metadata, secrets, missingSecretFields }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decode(Credential.self, forKey: .metadata)
        secrets = try c.decode([String: String].self, forKey: .secrets)
        missingSecretFields = try c.decodeIfPresent([String].self, forKey: .missingSecretFields) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metadata, forKey: .metadata)
        try c.encode(secrets, forKey: .secrets)
        // Preserve exact v1 bytes, including base/pending/transition recovery documents.
        if !missingSecretFields.isEmpty { try c.encode(missingSecretFields, forKey: .missingSecretFields) }
    }

    public var description: String { "CloudCredentialBundle(<redacted>)" }
    public var debugDescription: String { description }
}

public enum CloudVaultError: Error, LocalizedError, Equatable {
    case invalidSnapshot, unsupportedVersion, tooLarge, conflictingChanges, ambiguousNames

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshot: return "The sync snapshot is invalid or incomplete. Existing data was not changed."
        case .unsupportedVersion: return "This sync snapshot requires a different version of KeyKeeper."
        case .tooLarge: return "The sync snapshot exceeds this version's size limit. Existing data was not changed."
        case .conflictingChanges: return "Both Macs changed the same credential. Review both versions before continuing."
        case .ambiguousNames: return "Synced credentials have overlapping IDs or aliases. Existing data was not changed."
        }
    }
}

/// A complete, bounded unit. The transport must authenticate/decrypt before decoding this.
/// No independently arriving metadata and value records can be exposed as a partial credential.
public struct CloudVaultSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumBytes = 512 * 1024
    public private(set) var credentials: [String: CloudCredentialBundle]
    public var missingCredentialCount: Int { credentials.values.filter { !$0.missingSecretFields.isEmpty }.count }
    public var missingFieldCount: Int { credentials.values.reduce(0) { $0 + $1.missingSecretFields.count } }

    private struct Wire: Codable {
        let version: Int
        let credentials: [String: CloudCredentialBundle]
    }

    public init(credentials: [String: CloudCredentialBundle]) throws {
        self.credentials = credentials
        try validate()
        guard try canonicalData().count <= Self.maximumBytes else { throw CloudVaultError.tooLarge }
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try canonicalData()
        guard data.count <= Self.maximumBytes else { throw CloudVaultError.tooLarge }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw CloudVaultError.tooLarge }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw CloudVaultError.invalidSnapshot }
        guard wire.version == 1 || wire.version == 2 else { throw CloudVaultError.unsupportedVersion }
        let result = try Self(credentials: wire.credentials)
        // Only our canonical schema is accepted. Unknown fields (including future metadata)
        // must not silently disappear in a decode/re-encode cycle and then be uploaded as loss.
        guard try result.canonicalData() == data else { throw CloudVaultError.invalidSnapshot }
        return result
    }

    private func canonicalData() throws -> Data {
        try Self.encode(Wire(version: missingFieldCount == 0 ? 1 : 2, credentials: credentials))
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do { return try encoder.encode(value) }
        catch { throw CloudVaultError.invalidSnapshot }
    }

    private func validate() throws {
        guard credentials.count <= 4096 else { throw CloudVaultError.tooLarge }
        var names: [String: String] = [:]
        for (id, bundle) in credentials {
            guard !id.isEmpty, id.utf8.count <= 1024, bundle.metadata.fields.count <= 256 else {
                throw CloudVaultError.invalidSnapshot
            }
            for name in [id] + (bundle.metadata.aliases ?? []) {
                guard !name.isEmpty else { throw CloudVaultError.invalidSnapshot }
                if let owner = names[name], owner != id { throw CloudVaultError.ambiguousNames }
                names[name] = id
            }
            let secretFields = Set(bundle.metadata.fields.filter { $0.value.secret }.keys)
            let missing = Set(bundle.missingSecretFields), present = Set(bundle.secrets.keys)
            guard bundle.missingSecretFields == missing.sorted(),
                  missing.isDisjoint(with: present), missing.union(present) == secretFields else {
                throw CloudVaultError.invalidSnapshot
            }
            var fieldNames: [String: String] = [:]
            for (name, field) in bundle.metadata.fields {
                guard !name.isEmpty, name.utf8.count <= 1024,
                      !field.secret || field.value == nil else { throw CloudVaultError.invalidSnapshot }
                for alias in [name] + (field.aliases ?? []) {
                    guard !alias.isEmpty else { throw CloudVaultError.invalidSnapshot }
                    if let owner = fieldNames[alias], owner != name { throw CloudVaultError.ambiguousNames }
                    fieldNames[alias] = name
                }
            }
        }
    }

    public var description: String { "CloudVaultSnapshot(<redacted>)" }
    public var debugDescription: String { description }
}

public struct CloudVaultMergeResult: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let conflictingIDs: [String]
    fileprivate let merged: [String: CloudCredentialBundle]

    fileprivate init(merged: [String: CloudCredentialBundle], conflictingIDs: [String]) {
        self.merged = merged
        self.conflictingIDs = conflictingIDs
    }

    /// Partial merge results cannot be committed. The caller keeps both original snapshots
    /// encrypted for explicit conflict resolution; this result contains identifiers only.
    public func resolved() throws -> CloudVaultSnapshot {
        guard conflictingIDs.isEmpty else { throw CloudVaultError.conflictingChanges }
        return try CloudVaultSnapshot(credentials: merged)
    }

    public var description: String { "CloudVaultMergeResult(<redacted>)" }
    public var debugDescription: String { description }
}

public enum CloudVaultMerge {
    /// A review supplies exactly one choice for every divergent credential, including deletions.
    /// Strict review is used after an uncertain upload: no missing side is treated as a new item.
    public static func resolve(base: CloudVaultSnapshot?, local: CloudVaultSnapshot,
                               remote: CloudVaultSnapshot, choices: [String: CloudSyncChoice],
                               strict: Bool = false) throws -> CloudVaultSnapshot {
        let normal = strict ? nil : try merge(base: base, local: local, remote: remote)
        let conflicts = try normal?.conflictingIDs ?? divergentIDs(local: local, remote: remote)
        guard Set(choices.keys) == Set(conflicts) else { throw CloudVaultError.conflictingChanges }
        var merged = normal?.merged ?? local.credentials
        for id in conflicts {
            let pair = try completingMissing(local.credentials[id], remote.credentials[id])
            let chosen = choices[id] == .local ? pair.0 : pair.1
            guard preservesPresentValues(chosen, against: pair.0),
                  preservesPresentValues(chosen, against: pair.1) else { throw CloudVaultError.conflictingChanges }
            merged[id] = chosen
        }
        return try CloudVaultSnapshot(credentials: merged)
    }

    /// The UI and resolver share this guard; a missing marker is never an erase action.
    public static func canChoose(_ choice: CloudSyncChoice, local: CloudCredentialBundle?,
                                 remote: CloudCredentialBundle?) throws -> Bool {
        let pair = try completingMissing(local, remote)
        let selected = choice == .local ? pair.0 : pair.1
        return preservesPresentValues(selected, against: pair.0) && preservesPresentValues(selected, against: pair.1)
    }

    private static func preservesPresentValues(_ selected: CloudCredentialBundle?,
                                              against other: CloudCredentialBundle?) -> Bool {
        guard let selected, let other else { return true } // Actual group deletion remains explicit.
        return Set(selected.missingSecretFields).isDisjoint(with: other.secrets.keys)
    }

    private static func completingMissing(_ local: CloudCredentialBundle?, _ remote: CloudCredentialBundle?)
        throws -> (CloudCredentialBundle?, CloudCredentialBundle?) {
        guard var l = local, var r = remote,
              !l.missingSecretFields.isEmpty || !r.missingSecretFields.isEmpty,
              try CloudVaultSnapshot.encode(l.metadata) == CloudVaultSnapshot.encode(r.metadata) else { return (local, remote) }
        // Compare the whole credential contract, including provider/account/plain fields.
        // Historical base values are deliberately never used to repair current absence.
        for name in l.missingSecretFields { if let value = r.secrets[name] { l.secrets[name] = value } }
        for name in r.missingSecretFields { if let value = l.secrets[name] { r.secrets[name] = value } }
        l.missingSecretFields = l.missingSecretFields.filter { l.secrets[$0] == nil }
        r.missingSecretFields = r.missingSecretFields.filter { r.secrets[$0] == nil }
        return (l, r)
    }

    public static func divergentIDs(local: CloudVaultSnapshot, remote: CloudVaultSnapshot) throws -> [String] {
        try Set(local.credentials.keys).union(remote.credentials.keys).sorted().filter {
            try local.credentials[$0].map(CloudVaultSnapshot.encode) != remote.credentials[$0].map(CloudVaultSnapshot.encode)
        }
    }

    /// No clocks, transport IDs, or arrival order decide which value wins. A missing first-pairing
    /// base means additive union, NOT permission to delete credentials absent on the new Mac.
    public static func merge(base: CloudVaultSnapshot?, local: CloudVaultSnapshot,
                             remote: CloudVaultSnapshot) throws -> CloudVaultMergeResult {
        _ = try base?.encoded()
        _ = try local.encoded()
        _ = try remote.encoded()
        let ids = Set(local.credentials.keys).union(remote.credentials.keys)
            .union(base.map { Set($0.credentials.keys) } ?? [])
        var merged: [String: CloudCredentialBundle] = [:]
        var conflicts: [String] = []
        for id in ids.sorted() {
            let b = base?.credentials[id]
            let (l, r) = try completingMissing(local.credentials[id], remote.credentials[id])
            let bd = try b.map(CloudVaultSnapshot.encode)
            let ld = try l.map(CloudVaultSnapshot.encode)
            let rd = try r.map(CloudVaultSnapshot.encode)
            let chosen: CloudCredentialBundle?
            if ld == rd { chosen = l }
            else if ld == bd { chosen = r }
            else if rd == bd { chosen = l }
            else { conflicts.append(id); continue }
            guard preservesPresentValues(chosen, against: l), preservesPresentValues(chosen, against: r) else {
                conflicts.append(id); continue
            }
            merged[id] = chosen
        }
        // Independently valid snapshots can introduce an alias collision after merging. Fail
        // before any local/cloud commit rather than change what an existing CLI ID resolves to.
        if conflicts.isEmpty { _ = try CloudVaultSnapshot(credentials: merged) }
        return CloudVaultMergeResult(merged: merged, conflictingIDs: conflicts)
    }
}
