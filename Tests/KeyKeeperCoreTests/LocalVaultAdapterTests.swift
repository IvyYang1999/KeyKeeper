import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class LocalVaultAdapterTests: XCTestCase {
    private func credential() -> Credential {
        .init(label: "Synthetic", notes: "", links: [], fields: ["key": .init(secret: true)],
              security: .strict, created: "2026-11-02", updated: "2026-11-02")
    }

    private func fixture() throws -> (URL, MetaStore, FakeKeychainIO, FakeKeychainIO, LocalVaultCommitAdapter) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), approvals = FakeKeychainIO()
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        try meta.save(MetaFile(storeInitialized: true, credentials: ["fixture": credential()]))
        values.blob = try JSONEncoder().encode(KeychainBlobStore.Blob(version: 1,
            credentials: ["fixture": ["key": "synthetic-original", "orphan": "synthetic-preserved"]]))
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values,
            integrityIO: integrity, approvalsIO: approvals, namespace: "synthetic")
        return (directory, meta, values, approvals, adapter)
    }

    func testActualSignedFileAndValueIOProduceCompleteSnapshotWithoutWrites() throws {
        let (_, _, values, approvals, adapter) = try fixture()
        let snapshot = try adapter.snapshot()
        XCTAssertEqual(snapshot.credentials["fixture"]?.secrets, ["key": "synthetic-original"])
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(approvals.writes, 0)
    }

    func testExplicitMissingFieldsPreserveRecordWhileUnknownLocalDataRefuses() throws {
        let (_, _, values, _, adapter) = try fixture()
        values.blob = Data(#"{"version":1,"credentials":{"fixture":{}}}"#.utf8)
        let missing = try adapter.snapshot()
        XCTAssertEqual(missing.credentials.count, 1)
        XCTAssertEqual(missing.credentials["fixture"]?.missingSecretFields, ["key"])
        XCTAssertEqual(missing.credentials["fixture"]?.secrets, [:])
        values.blob = Data(#"{"version":1,"credentials":{"fixture":{"key":"synthetic"}},"future":1}"#.utf8)
        XCTAssertThrowsError(try adapter.snapshot())
        XCTAssertEqual(values.writes, 0)
    }

    private func coordinator(_ adapter: LocalVaultCommitAdapter) -> (LocalVaultCommitCoordinator, FakeKeychainIO, VaultAccessGate) {
        let io = FakeKeychainIO()
        let journal = LocalVaultJournal(io: io, marker: TestJournalMarker(), namespace: "synthetic")
        let gate = VaultAccessGate { try journal.requireReady() }
        return (LocalVaultCommitCoordinator(adapter: adapter, journal: journal, gate: gate), io, gate)
    }

    private func rotated(_ adapter: LocalVaultCommitAdapter) throws -> CloudVaultSnapshot {
        var bundle = try XCTUnwrap(adapter.snapshot().credentials["fixture"])
        bundle.secrets["key"] = "synthetic-rotated"
        bundle.metadata.notes = "Synthetic remote change"
        return try CloudVaultSnapshot(credentials: ["fixture": bundle])
    }

    private func grant(_ id: String) -> Approval {
        .init(subject: .init(fingerprint: "synthetic-caller", displayName: "Synthetic"),
              target: .credential(id: id, fields: nil), duration: .always)
    }

    func testActualCommitSignsMetadataPreservesOrphansAndOnlyRevokesChangedGrants() throws {
        let (_, meta, values, approvalsIO, adapter) = try fixture()
        let approvals = ApprovalStore(io: approvalsIO)
        try approvals.add(grant("fixture"))
        let unrelated = grant("unrelated")
        try approvals.add(unrelated)
        let persistedUnrelated = try approvals.approvals(forCredential: "unrelated")
        let (runtime, journalIO, _) = coordinator(adapter)
        let plan = try runtime.prepare(rotated(adapter))
        XCTAssertEqual(values.writes, 0, "preparation must not write values")
        XCTAssertEqual(journalIO.writes, 0, "preparation must not start the transaction")
        XCTAssertEqual(try runtime.commit(plan), ["fixture"])
        XCTAssertEqual(try meta.loadVerified().verdict, .intact)
        XCTAssertEqual(try meta.loadForUse().credentials["fixture"]?.notes, "Synthetic remote change")
        let blob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(values.blob))
        XCTAssertEqual(blob.credentials["fixture"]?["key"], "synthetic-rotated")
        XCTAssertEqual(blob.credentials["fixture"]?["orphan"], "synthetic-preserved")
        XCTAssertEqual(try approvals.all(), persistedUnrelated)
        // Completed replay cannot revoke a fresh, locally issued grant.
        try approvals.add(grant("fixture"))
        let count = approvalsIO.writes
        XCTAssertEqual(try runtime.commit(plan), [])
        XCTAssertEqual(approvalsIO.writes, count)
        XCTAssertTrue(try approvals.hasApprovals(forCredential: "fixture"))
    }

    func testValueWriteFailureKeepsJournalAndRecoveryDoesNotResurrectGrants() throws {
        let (_, meta, values, approvalsIO, adapter) = try fixture()
        let approvals = ApprovalStore(io: approvalsIO)
        try approvals.add(grant("fixture"))
        let (runtime, _, gate) = coordinator(adapter)
        let plan = try runtime.prepare(rotated(adapter))
        values.failWrites = true
        XCTAssertThrowsError(try runtime.commit(plan))
        XCTAssertThrowsError(try gate.withAccess {})
        XCTAssertFalse(try approvals.hasApprovals(forCredential: "fixture"))
        XCTAssertEqual(try Data(contentsOf: meta.fileURL), plan.before.metadata)
        values.failWrites = false
        XCTAssertEqual(try runtime.recover(), ["fixture"])
        XCTAssertEqual(try adapter.readImage(), plan.after)
        XCTAssertFalse(try approvals.hasApprovals(forCredential: "fixture"))
        XCTAssertNoThrow(try gate.withAccess {})
    }

    func testPermissiveModeAndOrphanCollisionRefuseWithoutWrites() throws {
        let (_, _, values, approvalsIO, adapter) = try fixture()
        let (runtime, journalIO, _) = coordinator(adapter)
        let desired = try rotated(adapter)
        let approvals = ApprovalStore(io: approvalsIO)
        try approvals.setMode(.permissive)
        XCTAssertThrowsError(try runtime.prepare(desired))
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(journalIO.writes, 0)
        try approvals.setMode(.enforced)
        var bundle = try XCTUnwrap(desired.credentials["fixture"])
        bundle.metadata.fields["orphan"] = .init(secret: true)
        bundle.secrets["orphan"] = "synthetic-collision"
        XCTAssertThrowsError(try runtime.prepare(CloudVaultSnapshot(credentials: ["fixture": bundle])))
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(journalIO.writes, 0)
    }

    func testForgedChangedIDsAndThirdStateRefuseBeforeAnyMutation() throws {
        let (_, meta, values, _, adapter) = try fixture()
        let (runtime, journalIO, _) = coordinator(adapter)
        let plan = try runtime.prepare(rotated(adapter))
        let forged = LocalVaultCommitPlan(id: plan.id, namespace: plan.namespace,
            expectedGeneration: plan.expectedGeneration, before: plan.before, after: plan.after,
            changedCredentialIDs: [])
        XCTAssertThrowsError(try runtime.commit(forged))
        var local = try meta.loadForUse()
        local.credentials["fixture"]?.label = "Synthetic local edit"
        try meta.save(local)
        XCTAssertThrowsError(try runtime.commit(plan))
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(journalIO.writes, 0)
        XCTAssertEqual(try meta.loadForUse().credentials["fixture"]?.label, "Synthetic local edit")
    }

    func testDeletingKnownCredentialRetainsUnreferencedRecoveryValue() throws {
        let (_, _, values, _, adapter) = try fixture()
        let (runtime, _, _) = coordinator(adapter)
        let plan = try runtime.prepare(CloudVaultSnapshot(credentials: [:]))
        try runtime.commit(plan)
        XCTAssertTrue(try adapter.snapshot().credentials.isEmpty)
        let blob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(values.blob))
        XCTAssertEqual(blob.credentials, ["fixture": ["orphan": "synthetic-preserved"]])
    }

    func testUnsignedBaselineDoesNotImplicitlyBootstrapDuringPreparation() throws {
        let (directory, meta, values, _, adapter) = try fixture()
        var unsigned = try meta.loadForUse()
        unsigned.integrity = nil
        try MetaStore(directory: directory).save(unsigned)
        let before = try adapter.readImage()
        let (runtime, journalIO, _) = coordinator(adapter)
        XCTAssertThrowsError(try runtime.prepare(CloudVaultSnapshot(credentials: [:])))
        XCTAssertEqual(try adapter.readImage(), before)
        XCTAssertEqual(values.writes, 0)
        XCTAssertEqual(journalIO.writes, 0)
    }
}
