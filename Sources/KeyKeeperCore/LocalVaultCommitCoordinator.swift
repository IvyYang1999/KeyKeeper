import Foundation

/// Local apply only. Cloud scheduling and multi-request CLI revision binding must
/// be integrated before exposing this backend as a user-facing sync switch.
public final class LocalVaultCommitCoordinator {
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
