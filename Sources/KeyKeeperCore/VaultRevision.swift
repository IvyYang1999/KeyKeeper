import Foundation
import CryptoKit

public enum VaultRevisionErrorCode: String, Codable, Sendable, Equatable {
    case stale, required, unavailable
}

public enum VaultRevisionError: Error, LocalizedError, Equatable {
    case stale, required, unavailable

    public var code: VaultRevisionErrorCode {
        switch self { case .stale: .stale; case .required: .required; case .unavailable: .unavailable }
    }
    public var errorDescription: String? {
        switch self {
        case .stale: "The credential store changed. Run the command again with a fresh snapshot."
        case .required: "This credential store requires a revision-aware KeyKeeper CLI. Update the CLI."
        case .unavailable: "A verified credential snapshot is unavailable."
        }
    }
}

/// A consistency precondition, never an authorization or a digest of protected values.
public struct VaultRevision: Codable, Sendable, Equatable {
    public var version: Int
    public var instanceID: UUID
    public var epoch: UInt64
    public var metadataDigest: String

    public init(version: Int = 1, instanceID: UUID, epoch: UInt64, metadataDigest: String) {
        self.version = version; self.instanceID = instanceID
        self.epoch = epoch; self.metadataDigest = metadataDigest
    }

    public func validate() throws {
        guard version == 1, metadataDigest.utf8.count == 64,
              metadataDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw VaultRevisionError.stale
        }
    }

    /// The sole canonical metadata implementation, shared by producer and consumer.
    public static func metadataDigest(for metadata: MetaFile) throws -> String {
        guard metadata.credentials.values.allSatisfy({ credential in
            credential.fields.values.allSatisfy { !$0.secret || $0.value == nil }
        }) else { throw VaultRevisionError.unavailable }
        return SHA256.hash(data: try canonicalEncoder().encode(metadata)).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case version, instanceID, epoch, metadataDigest }
    public init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: RevisionAnyKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw VaultRevisionError.stale
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        instanceID = try values.decode(UUID.self, forKey: .instanceID)
        epoch = try values.decode(UInt64.self, forKey: .epoch)
        metadataDigest = try values.decode(String.self, forKey: .metadataDigest)
        try validate()
    }
}

private struct RevisionAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

public struct VaultSnapshotRequest: Codable, Sendable {
    public var inspectValues: Bool
    public init(inspectValues: Bool = false) { self.inspectValues = inspectValues }
}

public struct VaultSnapshotResponse: Codable, Sendable {
    public static let maximumEncodedBytes = 900_000
    public var success: Bool
    public var metadata: MetaFile?
    public var revision: VaultRevision?
    public var valueInventory: [String: [String]]?
    public var error: String?

    public init(success: Bool, metadata: MetaFile? = nil, revision: VaultRevision? = nil,
                valueInventory: [String: [String]]? = nil, error: String? = nil) {
        self.success = success; self.metadata = metadata; self.revision = revision
        self.valueInventory = valueInventory; self.error = error
    }

    /// Must pass on the producer before encoding and on the consumer before using any field.
    @discardableResult public func validated() throws -> Self {
        guard success, let metadata, let revision, error == nil, metadata.version == 1 else {
            throw VaultRevisionError.unavailable
        }
        try revision.validate()
        guard revision.metadataDigest == (try VaultRevision.metadataDigest(for: metadata)) else {
            throw VaultRevisionError.stale
        }
        guard try JSONEncoder().encode(self).count <= Self.maximumEncodedBytes else {
            throw VaultRevisionError.unavailable
        }
        return self
    }
}
