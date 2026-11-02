import Foundation

/// One local transaction coordinator. Its IO adapter must share this gate with
/// all ordinary vault access. No network activity or authorization UI is started.
public final class LocalVaultCommitter {
    private let journal: LocalVaultJournal
    private let storage: any LocalVaultCommitStorage
    private let gate: VaultAccessGate

    public init(journal: LocalVaultJournal, storage: any LocalVaultCommitStorage, gate: VaultAccessGate) {
        self.journal = journal; self.storage = storage; self.gate = gate
    }

    @discardableResult public func commit(_ plan: LocalVaultCommitPlan) throws -> [String] {
        try gate.withAccess {
            try journal.validateShape(plan)
            let doc = try journal.load()
            guard doc?.pending == nil else { throw LocalVaultCommitError.pending }
            if doc?.generation == plan.id {
                guard doc?.lastDigest == (try journal.digest(plan)) else {
                    throw LocalVaultCommitError.identityMismatch
                }
                return [] // A replay must not revoke new grants or advance the epoch.
            }
            guard (doc?.generation ?? LocalVaultJournal.initialGeneration) == plan.expectedGeneration else {
                throw LocalVaultCommitError.staleGeneration
            }
            try storage.validate(plan)
            guard try storage.readImage() == plan.before else { throw LocalVaultCommitError.conflict }
            return try gate.withCommit {
                try journal.prepare(plan)
                return try applyPrepared(plan)
            }
        }
    }

    @discardableResult public func recover() throws -> [String] {
        try gate.withRecovery {
            guard let plan = try journal.recoverDocument()?.pending else { return [] }
            try storage.validate(plan)
            return try applyPrepared(plan)
        }
    }

    private func applyPrepared(_ plan: LocalVaultCommitPlan) throws -> [String] {
        // Check ALL resources before ANY effect, including revocation. A third
        // state is evidence of another writer, not permission to overwrite it.
        var image = try readKnownImage(plan)
        if !(try storage.approvalsAreRevoked(for: plan.changedCredentialIDs)) {
            do { try storage.revokeApprovals(for: plan.changedCredentialIDs) }
            catch { /* Read back before deciding whether the effect happened. */ }
            guard try storage.approvalsAreRevoked(for: plan.changedCredentialIDs) else {
                throw LocalVaultCommitError.unavailable
            }
        }
        image = try readKnownImage(plan)
        if image.values != plan.after.values {
            guard let values = plan.after.values else { throw LocalVaultCommitError.invalidPlan }
            do { try storage.writeValues(values, replacingExisting: image.values != nil) }
            catch { /* Resolve one uncertain attempt; never repeat the write here. */ }
            image = try readKnownImage(plan)
            guard image.values == plan.after.values else { throw LocalVaultCommitError.unavailable }
        }
        if image.metadata != plan.after.metadata {
            guard let metadata = plan.after.metadata else { throw LocalVaultCommitError.invalidPlan }
            do { try storage.writeMetadata(metadata) }
            catch { /* Exact readback is the only successful ambiguous outcome. */ }
            image = try readKnownImage(plan)
            guard image.metadata == plan.after.metadata else { throw LocalVaultCommitError.unavailable }
        }
        guard try storage.readImage() == plan.after,
              try storage.approvalsAreRevoked(for: plan.changedCredentialIDs) else {
            throw LocalVaultCommitError.conflict
        }
        try journal.finish(plan)
        return plan.changedCredentialIDs
    }

    private func readKnownImage(_ plan: LocalVaultCommitPlan) throws -> LocalVaultImage {
        let image = try storage.readImage()
        guard (image.metadata == plan.before.metadata || image.metadata == plan.after.metadata),
              (image.values == plan.before.values || image.values == plan.after.values) else {
            throw LocalVaultCommitError.conflict
        }
        return image
    }
}
