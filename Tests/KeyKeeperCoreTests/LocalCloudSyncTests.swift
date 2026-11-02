import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class LocalCloudSyncTests: XCTestCase {
    func testCaptureAndFirstIdenticalApplyInitializeJournal() throws {
        let f = try fixture()
        let captured = try f.runtime.capture()
        XCTAssertEqual(captured.snapshot.credentials["fixture"]?.secrets["key"], "synthetic-original")
        XCTAssertFalse(try f.journal.requiresBoundRequests())
        XCTAssertEqual(try f.runtime.apply(captured.snapshot, expectedRevision: captured.revision), [])
        XCTAssertTrue(try f.journal.requiresBoundRequests())
    }

    func testChangedLocalVersionDuringAwaitCannotBeOverwritten() throws {
        let f = try fixture()
        let original = try f.runtime.capture()
        var remote = try XCTUnwrap(original.snapshot.credentials["fixture"])
        remote.secrets["key"] = "synthetic-remote"
        let desired = try CloudVaultSnapshot(credentials: ["fixture": remote])
        var local = try f.meta.loadForUse()
        local.credentials["fixture"]?.notes = "new local edit"
        try f.meta.save(local)
        let bytes = f.values.blob
        XCTAssertThrowsError(try f.runtime.apply(desired, expectedRevision: original.revision)) {
            XCTAssertEqual($0 as? VaultRevisionError, .stale)
        }
        XCTAssertEqual(f.values.blob, bytes)
        XCTAssertEqual(try f.meta.loadForUse().credentials["fixture"]?.notes, "new local edit")
        XCTAssertFalse(try f.journal.requiresBoundRequests())
    }
    func testUnchangedSubsequentPollDoesNotInvalidatePendingApprovalRevision() throws {
        let f = try fixture()
        let first = try f.runtime.capture()
        _ = try f.runtime.apply(first.snapshot, expectedRevision: first.revision)
        let current = try f.runtime.capture()
        _ = try f.runtime.apply(current.snapshot, expectedRevision: current.revision)
        XCTAssertEqual(try f.runtime.capture().revision, current.revision)
    }
    func testImportedValuesAndMetadataKeepOrphans() throws {
        let f = try fixture()
        let current = try f.runtime.capture()
        var remote = try XCTUnwrap(current.snapshot.credentials["fixture"])
        remote.metadata.notes = "from other Mac"
        remote.secrets["key"] = "synthetic-remote"
        XCTAssertEqual(try f.runtime.apply(.init(credentials: ["fixture": remote]), expectedRevision: current.revision), ["fixture"])
        let after = try f.runtime.capture()
        XCTAssertEqual(after.snapshot.credentials["fixture"]?.metadata.notes, "from other Mac")
        XCTAssertEqual(after.snapshot.credentials["fixture"]?.secrets["key"], "synthetic-remote")
        let blob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(f.values.blob))
        XCTAssertEqual(blob.credentials["fixture"]?["orphan"], "synthetic-retained")
    }

    private struct Fixture {
        let runtime: LocalVaultCommitCoordinator
        let meta: MetaStore
        let values: FakeKeychainIO
        let journal: LocalVaultJournal
        let gate: VaultAccessGate
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), grants = FakeKeychainIO()
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        let credential = Credential(label: "Synthetic", notes: "", links: [], fields: ["key": .init(secret: true)],
            security: .strict, created: "2026-11-02", updated: "2026-11-02")
        try meta.save(.init(storeInitialized: true, credentials: ["fixture": credential]))
        values.blob = try JSONEncoder().encode(KeychainBlobStore.Blob(version: 1,
            credentials: ["fixture": ["key": "synthetic-original", "orphan": "synthetic-retained"]]))
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values,
            integrityIO: integrity, approvalsIO: grants, namespace: "synthetic-sync")
        let journal = LocalVaultJournal(io: FakeKeychainIO(), marker: TestJournalMarker(), namespace: "synthetic-sync")
        let gate = VaultAccessGate { try journal.requireReady() }
        return .init(runtime: .init(adapter: adapter, journal: journal, gate: gate), meta: meta,
                     values: values, journal: journal, gate: gate)
    }
}
