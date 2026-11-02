import Foundation

/// The local half of cloud synchronization: capture and apply share the same gate as
/// CLI requests, with an exact revision check across the intervening network work.
public final class LocalVaultCommitCoordinator: CloudSyncLocalStore, @unchecked Sendable {
    private let adapter: LocalVaultCommitAdapter
    private let journal: LocalVaultJournal
    private let gate: VaultAccessGate
    private let committer: LocalVaultCommitter

    init(adapter: LocalVaultCommitAdapter, journal: LocalVaultJournal, gate: VaultAccessGate) {
        self.adapter = adapter; self.journal = journal; self.gate = gate
        self.committer = LocalVaultCommitter(journal: journal, storage: adapter, gate: gate)
    }

    public static func production() throws -> LocalVaultCommitCoordinator {
        let journal = try LocalVaultJournal.production()
        let service = try SecItemBlobIO.serviceName(environment: ProcessInfo.processInfo.environment)
        let integrityIO = SecItemBlobIO(service: MetaIntegrityKey.service)
        let meta = MetaStore(directory: KeyKeeperPaths.applicationSupportDirectory, integrityIO: integrityIO)
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: SecItemBlobIO(service: service),
            integrityIO: integrityIO, approvalsIO: SecItemBlobIO(service: try ApprovalStore.serviceName()),
            namespace: journal.namespace)
        return Self(adapter: adapter, journal: journal, gate: .production)
    }

    /// Capture the values and the exact metadata revision inside one local lease.
    public func capture() throws -> CloudSyncLocalCapture {
        try gate.withAccess {
            guard try adapter.approvals.mode() == .enforced else { throw CloudSyncError.setupRequired }
            let image = try adapter.decoded(adapter.readImage())
            return try .init(snapshot: image.snapshot, revision: gate.revision(for: image.meta))
        }
    }

    /// The network caller must carry the revision captured before its awaits.
    public func apply(_ desired: CloudVaultSnapshot, expectedRevision: VaultRevision) throws -> [String] {
        try gate.withAccess {
            let current = try adapter.decoded(adapter.readImage())
            try gate.validateRevision(expectedRevision, metadata: current.meta, required: true)
            guard try adapter.approvals.mode() == .enforced else { throw CloudSyncError.setupRequired }
            // A successful no-op still initializes the journal once. Subsequent polling must
            // not invalidate waiting approvals when no credential changed.
            if try current.snapshot.encoded() == desired.encoded(), try journal.requiresBoundRequests() { return [] }
            return try committer.commit(adapter.prepare(desired, id: UUID(), generation: journal.generation()))
        }
    }

    /// Plan preparation is read-only. Unsigned/first-use vaults must finish their
    /// separately confirmed integrity bootstrap before they can join a sync commit.
    public func prepare(_ desired: CloudVaultSnapshot, id: UUID = UUID()) throws -> LocalVaultCommitPlan {
        try gate.withAccess {
            try adapter.prepare(desired, id: id, generation: journal.generation())
        }
    }

    @discardableResult
    public func commit(_ plan: LocalVaultCommitPlan) throws -> [String] { try committer.commit(plan) }

    @discardableResult
    public func recover() throws -> [String] { try committer.recover() }
}
