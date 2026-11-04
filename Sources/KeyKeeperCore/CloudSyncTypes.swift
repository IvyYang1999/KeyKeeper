import Foundation

public enum CloudSyncError: String, Codable, Error, Sendable, Equatable {
    case unavailable, accountChanged, conflict, pendingUpload, stateUnavailable, localChanged, setupRequired, busy
    case localDataUnavailable, unsupportedSnapshotVersion
}
public enum CloudSyncPhase: String, Codable, Sendable { case off, ready, syncing, synced, conflicts, paused }
public enum CloudSyncChoice: String, Codable, Sendable { case local, remote }

public struct CloudSyncBinding: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let container: String
    public let environment: String
    public let accountID: String
    public init(container: String, environment: String, accountID: String) {
        self.container = container; self.environment = environment; self.accountID = accountID
    }
    public func validate() throws {
        guard [container, accountID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }),
              ["Production", "Development"].contains(environment) else { throw CloudSyncError.accountChanged }
    }
    public var description: String { "CloudSyncBinding(<redacted>)" }
    public var debugDescription: String { description }
}

public struct CloudSyncRemote: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let revisionID: UUID
    public let snapshot: CloudVaultSnapshot
    public let changeToken: Data
    public init(revisionID: UUID, snapshot: CloudVaultSnapshot, changeToken: Data) {
        self.revisionID = revisionID; self.snapshot = snapshot; self.changeToken = changeToken
    }
    public var description: String { "CloudSyncRemote(<redacted>)" }
    public var debugDescription: String { description }
}

/// Secret-bearing local recovery data. Persist only in the dedicated local Keychain item.
public struct CloudSyncPendingUpload: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let snapshotData: Data
    public let expectedRevisionID: UUID?
    public let expectedChangeToken: Data?
    public init(id: UUID, snapshotData: Data, expectedRevisionID: UUID?, expectedChangeToken: Data?) {
        self.id = id; self.snapshotData = snapshotData
        self.expectedRevisionID = expectedRevisionID; self.expectedChangeToken = expectedChangeToken
    }
    public func validate() throws {
        _ = try snapshot()
        guard (expectedRevisionID == nil) == (expectedChangeToken == nil),
              expectedChangeToken.map({ !$0.isEmpty && $0.count <= 1024 * 1024 }) ?? true else {
            throw CloudSyncError.stateUnavailable
        }
    }
    public func snapshot() throws -> CloudVaultSnapshot { try CloudVaultSnapshot.decode(snapshotData) }
    public var description: String { "CloudSyncPendingUpload(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol CloudSyncTransport: AnyObject, Sendable {
    var hasOutstandingOperation: Bool { get }
    func binding() async throws -> CloudSyncBinding
    func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote?
    /// One conditional write only. Definite CAS rejection is `.conflict`; other failures are uncertain.
    func upload(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding) async throws
    func cancel()
    /// Synchronous fence shared with account-change notification; no check-to-effect gap.
    func withCurrentBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T
}
public struct CloudSyncLocalCapture: Sendable {
    public let snapshot: CloudVaultSnapshot
    public let revision: VaultRevision
    public init(snapshot: CloudVaultSnapshot, revision: VaultRevision) { self.snapshot = snapshot; self.revision = revision }
}
public protocol CloudSyncLocalStore: AnyObject, Sendable {
    func capture() throws -> CloudSyncLocalCapture
    /// Validate the original revision and prepare+commit inside the same outer vault gate.
    func apply(_ desired: CloudVaultSnapshot, expectedRevision: VaultRevision) throws -> [String]
}

public struct CloudSyncConflictRow: Equatable, Sendable, Identifiable {
    public var id: String { credentialID }
    public let credentialID: String
    public let title: String
    public let localDeleted: Bool
    public let remoteDeleted: Bool
    public let canChooseLocal: Bool
    public let canChooseRemote: Bool
    public init(credentialID: String, title: String, localDeleted: Bool, remoteDeleted: Bool,
                canChooseLocal: Bool = true, canChooseRemote: Bool = true) {
        self.credentialID = credentialID; self.title = title
        self.localDeleted = localDeleted; self.remoteDeleted = remoteDeleted
        self.canChooseLocal = canChooseLocal; self.canChooseRemote = canChooseRemote
    }
}
public struct CloudSyncStatus: Equatable, Sendable {
    public var enabled: Bool
    public var phase: CloudSyncPhase
    public var lastSuccess: Date?
    public var conflicts: [CloudSyncConflictRow]
    public var reviewID: UUID?
    public var error: CloudSyncError?
    public var busy: Bool
    public var canRetryPendingUpload: Bool
    public var missingCredentialCount: Int?
    public var missingFieldCount: Int?
    public init(enabled: Bool = false, phase: CloudSyncPhase = .off, lastSuccess: Date? = nil,
                conflicts: [CloudSyncConflictRow] = [], reviewID: UUID? = nil, error: CloudSyncError? = nil,
                busy: Bool = false, canRetryPendingUpload: Bool = false,
                missingCredentialCount: Int? = nil, missingFieldCount: Int? = nil) {
        self.enabled = enabled; self.phase = phase; self.lastSuccess = lastSuccess
        self.conflicts = conflicts; self.reviewID = reviewID; self.error = error
        self.busy = busy; self.canRetryPendingUpload = canRetryPendingUpload
        self.missingCredentialCount = missingCredentialCount; self.missingFieldCount = missingFieldCount
    }
}
