import Foundation

/// Raw images, including the distinction between a missing and an empty resource.
/// These bytes belong only in the local Keychain journal, never diagnostics or sync.
public struct LocalVaultImage: Codable, Equatable, Sendable, CustomStringConvertible {
    public let metadata: Data?
    public let values: Data?
    public init(metadata: Data?, values: Data?) { self.metadata = metadata; self.values = values }
    public var description: String { "LocalVaultImage(redacted)" }
}

public struct LocalVaultCommitPlan: Codable, Equatable, Sendable, CustomStringConvertible {
    public let id: UUID
    public let namespace: String
    public let expectedGeneration: UUID
    public let before: LocalVaultImage
    public let after: LocalVaultImage
    public let changedCredentialIDs: [String]
    public init(id: UUID, namespace: String, expectedGeneration: UUID, before: LocalVaultImage,
                after: LocalVaultImage, changedCredentialIDs: [String]) {
        self.id = id; self.namespace = namespace; self.expectedGeneration = expectedGeneration
        self.before = before; self.after = after; self.changedCredentialIDs = changedCredentialIDs
    }
    public var description: String { "LocalVaultCommitPlan(redacted)" }
}

/// The adapter independently validates signed images, complete inventories and the
/// affected-ID set. Its methods use raw storage under the outer operation gate.
public protocol LocalVaultCommitStorage: AnyObject {
    func validate(_ plan: LocalVaultCommitPlan) throws
    func readImage() throws -> LocalVaultImage
    func writeValues(_ data: Data, replacingExisting: Bool) throws
    func writeMetadata(_ data: Data) throws
    func revokeApprovals(for ids: [String]) throws
    func approvalsAreRevoked(for ids: [String]) throws -> Bool
}

public enum LocalVaultCommitError: Error, Equatable {
    case unavailable, malformed, pending, conflict, staleGeneration, identityMismatch, invalidPlan
}
