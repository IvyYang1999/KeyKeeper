import Foundation

/// Transport-independent secret-bearing data. Never log, expose over IPC, or write to a plain
/// file. This is deliberately NOT MetaFile: local integrity keys and grants are not portable.
public struct CloudCredentialBundle: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var metadata: Credential
    public var secrets: [String: String]

    public init(metadata: Credential, secrets: [String: String]) {
        self.metadata = metadata
        self.secrets = secrets
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
        guard wire.version == 1 else { throw CloudVaultError.unsupportedVersion }
        let result = try Self(credentials: wire.credentials)
        // Only our canonical schema is accepted. Unknown fields (including future metadata)
        // must not silently disappear in a decode/re-encode cycle and then be uploaded as loss.
        guard try result.canonicalData() == data else { throw CloudVaultError.invalidSnapshot }
        return result
    }

    private func canonicalData() throws -> Data {
        try Self.encode(Wire(version: 1, credentials: credentials))
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
            guard Set(bundle.secrets.keys) == secretFields else { throw CloudVaultError.invalidSnapshot }
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
    private let merged: [String: CloudCredentialBundle]

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
            let b = base?.credentials[id], l = local.credentials[id], r = remote.credentials[id]
            let bd = try b.map(CloudVaultSnapshot.encode)
            let ld = try l.map(CloudVaultSnapshot.encode)
            let rd = try r.map(CloudVaultSnapshot.encode)
            if ld == rd { merged[id] = l }
            else if ld == bd { merged[id] = r }
            else if rd == bd { merged[id] = l }
            else { conflicts.append(id) }
        }
        // Independently valid snapshots can introduce an alias collision after merging. Fail
        // before any local/cloud commit rather than change what an existing CLI ID resolves to.
        if conflicts.isEmpty { _ = try CloudVaultSnapshot(credentials: merged) }
        return CloudVaultMergeResult(merged: merged, conflictingIDs: conflicts)
    }
}
