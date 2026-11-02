import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class LocalVaultCommitterTests: XCTestCase {
    func testCommitAndCompletedReplay() throws {
        let h = CommitHarness()
        let epoch = try h.gate.captureEpoch()
        XCTAssertEqual(try h.committer.commit(h.plan), ["credential"])
        XCTAssertEqual(h.storage.image, h.plan.after)
        XCTAssertEqual(h.storage.effects, ["revoke", "values", "metadata"])
        XCTAssertEqual(try h.journal.generation(), h.plan.id)
        let completed = String(decoding: try XCTUnwrap(h.io.blob), as: UTF8.self)
        XCTAssertFalse(completed.contains("pending"))
        XCTAssertFalse(completed.contains(Data("before-secret".utf8).base64EncodedString()))
        XCTAssertFalse(completed.contains(Data("after-secret".utf8).base64EncodedString()))
        XCTAssertThrowsError(try h.gate.withAccess(expectedEpoch: epoch) {})
        let writes = h.io.writes
        let committedEpoch = try h.gate.captureEpoch()
        XCTAssertEqual(try h.committer.commit(h.plan), [])
        XCTAssertEqual(h.io.writes, writes)
        XCTAssertEqual(h.storage.effects.count, 3)
        XCTAssertEqual(try h.gate.captureEpoch(), committedEpoch)
    }

    func testCrashBeforeMetadataRecoversForward() throws {
        let h = CommitHarness()
        h.storage.failBefore = "metadata"
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertEqual(h.storage.image.values, h.plan.after.values)
        XCTAssertEqual(h.storage.image.metadata, h.plan.before.metadata)
        XCTAssertThrowsError(try h.gate.withAccess {})
        XCTAssertThrowsError(try h.journal.requireReady())
        h.storage.failBefore = nil
        let recovered = h.restarted()
        XCTAssertEqual(try recovered.recover(), ["credential"])
        XCTAssertEqual(h.storage.image, h.plan.after)
        let writes = h.io.writes
        let effects = h.storage.effects
        XCTAssertEqual(try recovered.recover(), [])
        XCTAssertEqual(h.io.writes, writes)
        XCTAssertEqual(h.storage.effects, effects)
    }

    func testThirdStateIsNeverOverwritten() throws {
        let h = CommitHarness()
        h.storage.failBefore = "metadata"
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        h.storage.failBefore = nil
        h.storage.image = LocalVaultImage(metadata: Data("external-change".utf8), values: h.plan.after.values)
        let effects = h.storage.effects
        XCTAssertThrowsError(try h.restarted().recover())
        XCTAssertEqual(h.storage.effects, effects)
        XCTAssertEqual(h.storage.image.metadata, Data("external-change".utf8))
    }

    func testFailedPrepareNeverTouchesDataAndCanBeRetriedAfterRecovery() throws {
        let h = CommitHarness()
        h.io.failWrites = true
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertEqual(h.storage.image, h.plan.before)
        XCTAssertEqual(h.storage.effects, [])
        XCTAssertFalse(h.marker.created)
        h.io.failWrites = false
        XCTAssertEqual(try h.committer.recover(), [])
        XCTAssertEqual(try h.committer.commit(h.plan), ["credential"])
    }

    func testDataWriteBeforeAndAfterFailuresHaveOneAttemptAndRecover() throws {
        for phase in ["revoke", "values", "metadata"] {
            let before = CommitHarness()
            before.storage.failBefore = phase
            XCTAssertThrowsError(try before.committer.commit(before.plan), phase)
            XCTAssertThrowsError(try before.gate.withAccess {})
            before.storage.failBefore = nil
            XCTAssertEqual(try before.restarted().recover(), ["credential"])
            XCTAssertEqual(before.storage.image, before.plan.after)
            XCTAssertEqual(before.storage.effects, ["revoke", "values", "metadata"])

            let after = CommitHarness()
            after.storage.failAfter = phase
            XCTAssertEqual(try after.committer.commit(after.plan), ["credential"], phase)
            XCTAssertEqual(after.storage.image, after.plan.after)
            XCTAssertEqual(after.storage.effects, ["revoke", "values", "metadata"])
        }
    }

    func testUnreadableWriteOutcomePreservesPendingUntilRestart() throws {
        for phase in ["revoke", "values", "metadata"] {
            let h = CommitHarness()
            h.storage.afterEffect = { name in
                if name == phase { h.storage.failReads = true }
            }
            XCTAssertThrowsError(try h.committer.commit(h.plan), phase)
            XCTAssertThrowsError(try h.gate.withAccess {})
            XCTAssertThrowsError(try h.journal.requireReady())
            h.storage.afterEffect = nil
            h.storage.failReads = false
            XCTAssertEqual(try h.restarted().recover(), ["credential"])
            XCTAssertEqual(h.storage.image, h.plan.after)
            XCTAssertEqual(h.storage.effects, ["revoke", "values", "metadata"])
        }
    }

    func testEveryJournalWriteCanFailBeforeOrBecomeUnknownAfter() throws {
        for write in 1...3 {
            for after in [false, true] {
                let h = CommitHarness()
                if after {
                    h.io.afterWrite = {
                        if h.io.writes == write { h.io.failReads = true; throw LocalVaultCommitError.unavailable }
                    }
                } else {
                    h.io.onRead = {
                        if h.io.writes == write - 1 { h.io.failWrites = true }
                    }
                }
                XCTAssertThrowsError(try h.committer.commit(h.plan), "write \(write) after \(after)")
                XCTAssertThrowsError(try h.gate.withAccess {})
                h.io.afterWrite = nil; h.io.onRead = nil
                h.io.failReads = false; h.io.failWrites = false
                let restarted = h.restarted()
                _ = try restarted.recover()
                _ = try restarted.commit(h.plan)
                XCTAssertEqual(h.storage.image, h.plan.after)
                XCTAssertEqual(h.storage.effects, ["revoke", "values", "metadata"])
                let writes = h.io.writes
                _ = try restarted.recover()
                XCTAssertEqual(h.io.writes, writes)
            }
        }
    }

    func testAmbiguousJournalWriteWithExactReadbackSucceeds() throws {
        let h = CommitHarness()
        h.io.afterWrite = { throw LocalVaultCommitError.unavailable }
        XCTAssertEqual(try h.committer.commit(h.plan), ["credential"])
        XCTAssertEqual(h.io.writes, 3)
        XCTAssertEqual(h.storage.effects, ["revoke", "values", "metadata"])
    }

    func testIdentityReuseAndStaleGenerationNeverWrite() throws {
        let h = CommitHarness()
        _ = try h.committer.commit(h.plan)
        let changed = LocalVaultCommitPlan(id: h.plan.id, namespace: "test", expectedGeneration: h.plan.expectedGeneration,
            before: h.plan.before, after: LocalVaultImage(metadata: h.plan.after.metadata, values: Data("other-secret".utf8)),
            changedCredentialIDs: ["credential"])
        let writes = h.io.writes
        XCTAssertThrowsError(try h.committer.commit(changed)) {
            XCTAssertEqual($0 as? LocalVaultCommitError, .identityMismatch)
        }
        let stale = LocalVaultCommitPlan(id: UUID(), namespace: "test", expectedGeneration: h.plan.expectedGeneration,
            before: h.plan.after, after: h.plan.before, changedCredentialIDs: ["credential"])
        XCTAssertThrowsError(try h.committer.commit(stale)) {
            XCTAssertEqual($0 as? LocalVaultCommitError, .staleGeneration)
        }
        XCTAssertEqual(h.io.writes, writes)
        XCTAssertEqual(h.storage.effects.count, 3)
    }

    func testOlderImmutablePlanCannotReplayAfterAnotherCommitEvenAfterABA() throws {
        let h = CommitHarness()
        _ = try h.committer.commit(h.plan)
        let second = LocalVaultCommitPlan(id: UUID(), namespace: "test", expectedGeneration: h.plan.id,
            before: h.plan.after, after: h.plan.before, changedCredentialIDs: ["credential"])
        _ = try h.committer.commit(second)
        XCTAssertEqual(h.storage.image, h.plan.before)
        let writes = h.io.writes
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertEqual(h.io.writes, writes)
    }

    func testInvalidChangedIDsAndStaleImageNeverPrepareJournal() throws {
        let h = CommitHarness()
        let invalid = LocalVaultCommitPlan(id: UUID(), namespace: "test", expectedGeneration: h.plan.expectedGeneration,
            before: h.plan.before, after: h.plan.after, changedCredentialIDs: ["unrelated"])
        XCTAssertThrowsError(try h.committer.commit(invalid))
        h.storage.image = h.plan.after
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertEqual(h.io.writes, 0)
        XCTAssertEqual(h.storage.effects, [])
    }

    func testRecoveryRevalidatesPlanAndDoesNotRestoreRevokedApprovals() throws {
        let h = CommitHarness()
        h.storage.failBefore = "values"
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertTrue(h.storage.revoked)
        h.storage.validationError = true
        let effects = h.storage.effects
        XCTAssertThrowsError(try h.restarted().recover())
        XCTAssertEqual(h.storage.effects, effects)
        XCTAssertTrue(h.storage.revoked)
        h.storage.validationError = false; h.storage.failBefore = nil
        _ = try h.restarted().recover()
        XCTAssertEqual(h.storage.effects.filter { $0 == "revoke" }.count, 1)
    }

    func testAlreadyDesiredResourceIsNotRewrittenDuringRecovery() throws {
        for valuesAreAfter in [false, true] {
            let h = CommitHarness()
            h.storage.failBefore = "revoke"
            XCTAssertThrowsError(try h.committer.commit(h.plan))
            h.storage.failBefore = nil
            h.storage.image = LocalVaultImage(metadata: valuesAreAfter ? h.plan.before.metadata : h.plan.after.metadata,
                values: valuesAreAfter ? h.plan.after.values : h.plan.before.values)
            _ = try h.restarted().recover()
            XCTAssertEqual(h.storage.image, h.plan.after)
            XCTAssertFalse(h.storage.effects.contains(valuesAreAfter ? "values" : "metadata"))
        }
    }
}

final class CommitHarness {
    let io = FakeKeychainIO()
    let marker = TestJournalMarker()
    let storage: TestCommitStorage
    let plan: LocalVaultCommitPlan
    let journal: LocalVaultJournal
    let gate: VaultAccessGate
    let committer: LocalVaultCommitter
    init() {
        let before = LocalVaultImage(metadata: Data("before-meta".utf8), values: Data("before-secret".utf8))
        let after = LocalVaultImage(metadata: Data("after-meta".utf8), values: Data("after-secret".utf8))
        plan = LocalVaultCommitPlan(id: UUID(), namespace: "test", expectedGeneration: LocalVaultJournal.initialGeneration,
                                   before: before, after: after, changedCredentialIDs: ["credential"])
        storage = TestCommitStorage(image: before)
        journal = LocalVaultJournal(io: io, marker: marker, namespace: "test")
        let capturedJournal = journal
        gate = VaultAccessGate(admission: { try capturedJournal.requireReady() })
        committer = LocalVaultCommitter(journal: journal, storage: storage, gate: gate)
    }
    func restarted() -> LocalVaultCommitter {
        let journal = LocalVaultJournal(io: io, marker: marker, namespace: "test")
        let gate = VaultAccessGate(admission: { try journal.requireReady() })
        return LocalVaultCommitter(journal: journal, storage: storage, gate: gate)
    }
}

final class TestCommitStorage: LocalVaultCommitStorage {
    var image: LocalVaultImage
    var effects: [String] = []
    var revoked = false
    var failBefore: String?
    var failAfter: String?
    var failReads = false
    var validationError = false
    var afterEffect: ((String) -> Void)?
    init(image: LocalVaultImage) { self.image = image }
    func validate(_ plan: LocalVaultCommitPlan) throws {
        if validationError { throw LocalVaultCommitError.invalidPlan }
        guard plan.changedCredentialIDs == ["credential"] else { throw LocalVaultCommitError.invalidPlan }
    }
    func readImage() throws -> LocalVaultImage {
        if failReads { throw LocalVaultCommitError.unavailable }; return image
    }
    func writeValues(_ data: Data, replacingExisting: Bool) throws {
        try effect("values") { image = LocalVaultImage(metadata: image.metadata, values: data) }
    }
    func writeMetadata(_ data: Data) throws {
        try effect("metadata") { image = LocalVaultImage(metadata: data, values: image.values) }
    }
    func revokeApprovals(for ids: [String]) throws { try effect("revoke") { revoked = true } }
    func approvalsAreRevoked(for ids: [String]) throws -> Bool {
        if failReads { throw LocalVaultCommitError.unavailable }; return revoked
    }
    private func effect(_ name: String, _ body: () -> Void) throws {
        if failBefore == name { throw LocalVaultCommitError.unavailable }
        effects.append(name); body(); afterEffect?(name)
        if failAfter == name { throw LocalVaultCommitError.unavailable }
    }
}
