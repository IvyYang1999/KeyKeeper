import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class LocalVaultMissingValueTests: XCTestCase {
    private struct Fixture {
        let meta: MetaStore
        let integrity: FakeKeychainIO
        let values: FakeKeychainIO
        let grants: FakeKeychainIO
        let journalIO: FakeKeychainIO
        let adapter: LocalVaultCommitAdapter
        let journal: LocalVaultJournal
        let local: LocalVaultCommitCoordinator
    }

    private func fixture(initialized: Bool? = true) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-missing-adapter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), grants = FakeKeychainIO(), journalIO = FakeKeychainIO()
        let meta = MetaStore(directory: dir, integrityIO: integrity)
        let complete = Credential(label: "Synthetic complete", notes: "Keep this note", links: [],
            fields: ["key": .init(secret: true)], security: .strict, created: "2026-11-04", updated: "2026-11-04")
        var partial = complete
        partial.label = "Synthetic historical missing"
        partial.fields["retained"] = .init(secret: true)
        partial.fields["region"] = .init(value: "synthetic-region", secret: false)
        try meta.save(.init(storeInitialized: initialized, credentials: ["complete": complete, "partial": partial]))
        values.blob = try CloudVaultSnapshot.encode(KeychainBlobStore.Blob(version: 1, credentials: [
            "complete": ["key": "synthetic-complete"],
            "partial": ["retained": "synthetic-retained", "orphan": "synthetic-recovery"],
            "orphan-group": ["key": "synthetic-orphan-group"]
        ]))
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values, integrityIO: integrity,
            approvalsIO: grants, namespace: "synthetic-missing")
        let journal = LocalVaultJournal(io: journalIO, marker: TestJournalMarker(), namespace: "synthetic-missing")
        let local = LocalVaultCommitCoordinator(adapter: adapter, journal: journal,
            gate: VaultAccessGate { try journal.requireReady() })
        return .init(meta: meta, integrity: integrity, values: values, grants: grants,
                     journalIO: journalIO, adapter: adapter, journal: journal, local: local)
    }

    private func grant(_ id: String) -> Approval {
        .init(subject: .init(fingerprint: "synthetic-only", displayName: "Synthetic"),
              target: .credential(id: id, fields: nil), duration: .always)
    }

    private func repaired(_ snapshot: CloudVaultSnapshot) throws -> CloudVaultSnapshot {
        var entries = snapshot.credentials
        entries["partial"]?.secrets["key"] = "synthetic-restored"
        entries["partial"]?.missingSecretFields = []
        return try .init(credentials: entries)
    }

    func testMixedCapturePreservesAllMetadataAndPresentValuesWithoutWrites() throws {
        let f = try fixture(), before = try f.adapter.readImage()
        let snapshot = try f.local.capture().snapshot
        XCTAssertEqual(snapshot.credentials.count, 2)
        XCTAssertEqual(snapshot.missingCredentialCount, 1)
        XCTAssertEqual(snapshot.missingFieldCount, 1)
        XCTAssertEqual(snapshot.credentials["partial"]?.missingSecretFields, ["key"])
        XCTAssertEqual(snapshot.credentials["partial"]?.secrets, ["retained": "synthetic-retained"])
        XCTAssertEqual(snapshot.credentials["complete"]?.secrets, ["key": "synthetic-complete"])
        XCTAssertEqual(snapshot.credentials["partial"]?.metadata.fields["region"]?.value, "synthetic-region")
        XCTAssertEqual(snapshot.credentials["partial"]?.metadata.notes, "Keep this note")
        XCTAssertNil(snapshot.credentials["orphan-group"])
        XCTAssertEqual(try f.adapter.readImage(), before)
        XCTAssertEqual(f.values.writes + f.grants.writes + f.journalIO.writes, 0)
    }

    func testMissingEntireBlobRefusesEvenWhenInitializationMarkerIsAbsentOrFalse() throws {
        for initialized in [nil, false, true] as [Bool?] {
            let f = try fixture(initialized: initialized)
            f.values.blob = nil
            XCTAssertThrowsError(try f.local.capture())
            XCTAssertEqual(f.values.writes + f.grants.writes + f.journalIO.writes, 0)
            // A readable, valid empty blob represents absent fields, not an absent store.
            f.values.blob = try CloudVaultSnapshot.encode(KeychainBlobStore.Blob(version: 1, credentials: [:]))
            let snapshot = try f.local.capture().snapshot
            XCTAssertEqual(snapshot.credentials.count, 2)
            XCTAssertEqual(snapshot.missingFieldCount, 3)
        }
    }

    func testDeniedCorruptUnknownAndMissingIntegrityNeverBecomeMissingMarkers() throws {
        let f = try fixture(), valid = f.values.blob
        f.values.failReads = true
        XCTAssertThrowsError(try f.local.capture())
        f.values.failReads = false
        for invalid in [Data("not-json".utf8), Data(#"{"version":1,"credentials":{},"unknown":1}"#.utf8)] {
            f.values.blob = invalid
            XCTAssertThrowsError(try f.local.capture())
        }
        f.values.blob = valid
        f.integrity.blob = nil
        XCTAssertThrowsError(try f.local.capture())
        XCTAssertEqual(f.values.writes + f.grants.writes + f.journalIO.writes, 0)
    }

    func testPresentToMissingIsRejectedByPreparationAndIndependentPlanValidation() throws {
        let f = try fixture()
        var entries = try f.local.capture().snapshot.credentials
        entries["complete"]?.secrets = [:]
        entries["complete"]?.missingSecretFields = ["key"]
        let desired = try CloudVaultSnapshot(credentials: entries)
        let before = try f.adapter.readImage()
        XCTAssertThrowsError(try f.local.prepare(desired))
        var forgedBlob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(before.values))
        forgedBlob.credentials["complete"] = [:]
        let forged = LocalVaultCommitPlan(id: UUID(), namespace: "synthetic-missing",
            expectedGeneration: LocalVaultJournal.initialGeneration, before: before,
            after: .init(metadata: before.metadata, values: try CloudVaultSnapshot.encode(forgedBlob)),
            changedCredentialIDs: ["complete"])
        XCTAssertThrowsError(try f.adapter.validate(forged))
        XCTAssertThrowsError(try f.local.commit(forged))
        XCTAssertEqual(try f.adapter.readImage(), before)
        XCTAssertEqual(f.values.writes + f.grants.writes + f.journalIO.writes, 0)
    }

    func testMissingRepairCommitRecoversAndRevokesOnlyChangedCredentialGrant() throws {
        let f = try fixture()
        let grants = ApprovalStore(io: f.grants)
        try grants.add(grant("partial")); try grants.add(grant("complete"))
        let unaffected = try grants.approvals(forCredential: "complete")
        let initial = try f.local.capture().snapshot
        let desired = try repaired(initial)
        XCTAssertEqual(initial.missingFieldCount, 1)
        XCTAssertEqual(desired.missingFieldCount, 0)
        let plan = try f.local.prepare(desired)
        f.values.failWrites = true
        XCTAssertThrowsError(try f.local.commit(plan))
        XCTAssertFalse(try grants.hasApprovals(forCredential: "partial"))
        XCTAssertEqual(try grants.approvals(forCredential: "complete"), unaffected)
        f.values.failWrites = false
        let restarted = LocalVaultCommitCoordinator(adapter: f.adapter, journal: f.journal,
            gate: VaultAccessGate { try f.journal.requireReady() })
        XCTAssertEqual(try restarted.recover(), ["partial"])
        XCTAssertEqual(try restarted.capture().snapshot.encoded(), try desired.encoded())
        XCTAssertEqual(try f.meta.loadVerified().verdict, .intact)
        let persisted = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(f.values.blob))
        XCTAssertEqual(persisted.credentials["partial"]?["key"], "synthetic-restored")
        XCTAssertEqual(persisted.credentials["partial"]?["retained"], "synthetic-retained")
        XCTAssertEqual(persisted.credentials["partial"]?["orphan"], "synthetic-recovery")
        XCTAssertEqual(persisted.credentials["orphan-group"]?["key"], "synthetic-orphan-group")
        try grants.add(grant("partial"))
        let writes = f.grants.writes
        XCTAssertEqual(try restarted.commit(plan), [])
        XCTAssertEqual(f.grants.writes, writes)
        XCTAssertTrue(try grants.hasApprovals(forCredential: "partial"))
    }

    func testMissingNoopPreservesRecordsAndDoesNotRevokeGrantsOrRewriteRepeatedly() throws {
        let f = try fixture()
        let grants = ApprovalStore(io: f.grants)
        try grants.add(grant("partial"))
        let first = try f.local.capture()
        XCTAssertEqual(try f.local.apply(first.snapshot, expectedRevision: first.revision), [])
        let initializedImage = try f.adapter.readImage()
        let counts = [f.values.writes, f.grants.writes, f.journalIO.writes]
        let again = try f.local.capture()
        XCTAssertEqual(try f.local.apply(again.snapshot, expectedRevision: again.revision), [])
        XCTAssertEqual([f.values.writes, f.grants.writes, f.journalIO.writes], counts)
        XCTAssertEqual(try f.adapter.readImage(), initializedImage)
        XCTAssertEqual(again.snapshot.missingFieldCount, 1)
        XCTAssertTrue(try grants.hasApprovals(forCredential: "partial"))
    }

    func testExplicitFieldAndGroupDeletionRemainDistinctFromMissing() throws {
        for deleteGroup in [false, true] {
            let f = try fixture()
            var entries = try f.local.capture().snapshot.credentials
            if deleteGroup { entries.removeValue(forKey: "partial") }
            else {
                entries["partial"]?.metadata.fields.removeValue(forKey: "retained")
                entries["partial"]?.secrets.removeValue(forKey: "retained")
            }
            let desired = try CloudVaultSnapshot(credentials: entries)
            let plan = try f.local.prepare(desired)
            XCTAssertEqual(try f.local.commit(plan), ["partial"])
            XCTAssertEqual(try f.local.capture().snapshot.encoded(), try desired.encoded())
            let blob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(f.values.blob))
            XCTAssertNil(blob.credentials["partial"]?["retained"])
            XCTAssertEqual(blob.credentials["partial"]?["orphan"], "synthetic-recovery")
        }
    }
}
