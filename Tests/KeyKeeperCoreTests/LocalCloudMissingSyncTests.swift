import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// Two independent local vaults through the production journal/coordinator/state stores.
/// Only Keychain IO and the conditional cloud transport are fake; no App or native cloud.
final class LocalCloudMissingSyncTests: XCTestCase {
    func testMixedVaultPairsRepairsAndReloadsWithoutLosingRecordsOrTransferringGrants() async throws {
        let cloud = MissingSyncCloud()
        let a = try fixture(name: "a", mixed: true), b = try fixture(name: "b", mixed: false)
        let grantsA = ApprovalStore(io: a.grants), grantsB = ApprovalStore(io: b.grants)
        try grantsA.add(grant("complete")); try grantsA.add(grant("partial"))
        let keptGrant = try grantsA.approvals(forCredential: "complete")
        let first = a.open(cloud), second = b.open(cloud)
        await first.engine.load(); await second.engine.load()
        let off = await first.engine.status
        XCTAssertFalse(off.enabled)
        XCTAssertNil(off.missingFieldCount)
        XCTAssertEqual(cloud.uploads, 0)

        await first.engine.enable()
        let uploaded = await first.engine.status
        XCTAssertEqual(uploaded.phase, .synced)
        XCTAssertEqual(uploaded.missingCredentialCount, 1)
        XCTAssertEqual(uploaded.missingFieldCount, 1)
        let initial = try XCTUnwrap(cloud.snapshot)
        XCTAssertEqual(Set(initial.credentials.keys), ["complete", "partial"])
        XCTAssertEqual(initial.credentials["partial"]?.missingSecretFields, ["key"])
        XCTAssertEqual(initial.credentials["partial"]?.secrets, [:])
        XCTAssertEqual(try version(initial), 2)
        XCTAssertNil(initial.credentials["complete"]?.secrets["orphan"])
        XCTAssertNil(initial.credentials["orphan-group"])
        XCTAssertEqual(cloud.uploads, 1)

        XCTAssertTrue(try second.local.capture().snapshot.credentials.isEmpty)
        await second.engine.enable()
        let paired = await second.engine.status
        XCTAssertEqual(paired.phase, .synced)
        let received = try second.local.capture().snapshot
        XCTAssertEqual(try received.encoded(), try initial.encoded())
        XCTAssertEqual(received.credentials["partial"]?.metadata.notes, "Synthetic history remains")
        XCTAssertTrue(try grantsB.all().isEmpty, "A's caller grants cannot travel in the snapshot")
        XCTAssertEqual(try grantsA.all().count, 2)
        XCTAssertEqual(cloud.uploads, 1, "Receiving an existing head does not republish it")

        let capturedB = try second.local.capture()
        var entries = capturedB.snapshot.credentials
        entries["partial"]?.missingSecretFields = []
        entries["partial"]?.secrets["key"] = "synthetic-repaired-on-b"
        let repaired = try CloudVaultSnapshot(credentials: entries)
        XCTAssertEqual(try second.local.apply(repaired, expectedRevision: capturedB.revision), ["partial"])
        await second.engine.syncNow()
        let repairedB = await second.engine.status
        XCTAssertEqual(repairedB.phase, .synced)
        XCTAssertEqual(repairedB.missingFieldCount, 0)
        XCTAssertEqual(cloud.uploads, 2)
        XCTAssertEqual(try version(XCTUnwrap(cloud.snapshot)), 1)

        await first.engine.syncNow()
        let repairedA = await first.engine.status
        XCTAssertEqual(repairedA.phase, .synced)
        XCTAssertEqual(repairedA.missingFieldCount, 0)
        XCTAssertEqual(try first.local.capture().snapshot.encoded(), try repaired.encoded())
        XCTAssertFalse(try grantsA.hasApprovals(forCredential: "partial"))
        XCTAssertEqual(try grantsA.approvals(forCredential: "complete"), keptGrant)
        XCTAssertTrue(try grantsB.all().isEmpty)
        let aBlob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(a.values.blob))
        XCTAssertEqual(aBlob.credentials["complete"]?["orphan"], "synthetic-local-only")
        XCTAssertEqual(aBlob.credentials["orphan-group"]?["key"], "synthetic-unreferenced")
        let bBlob = try JSONDecoder().decode(KeychainBlobStore.Blob.self, from: XCTUnwrap(b.values.blob))
        XCTAssertNil(bBlob.credentials["complete"]?["orphan"])
        XCTAssertNil(bBlob.credentials["orphan-group"])

        // Recreate the engines, adapters, journals and state-store objects from persisted IO.
        let restartedA = a.open(cloud), restartedB = b.open(cloud)
        let uploads = cloud.uploads
        await restartedA.engine.load(); await restartedB.engine.load()
        await restartedA.engine.syncNow(); await restartedB.engine.syncNow()
        let statusA = await restartedA.engine.status, statusB = await restartedB.engine.status
        XCTAssertEqual(statusA.phase, .synced); XCTAssertEqual(statusB.phase, .synced)
        XCTAssertEqual(cloud.uploads, uploads)
        XCTAssertEqual(try restartedA.local.capture().snapshot.encoded(), try repaired.encoded())
        XCTAssertEqual(try restartedB.local.capture().snapshot.encoded(), try repaired.encoded())
        XCTAssertEqual(try restartedA.state.load()?.baseData, try repaired.encoded())
        XCTAssertEqual(try restartedB.state.load()?.baseData, try repaired.encoded())
        XCTAssertNil(try restartedA.state.load()?.pending)
        XCTAssertNil(try restartedB.state.load()?.transition)
    }

    private func version(_ snapshot: CloudVaultSnapshot) throws -> Int? {
        (try JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])?["version"] as? Int
    }

    private func grant(_ id: String) -> Approval {
        .init(subject: .init(fingerprint: "synthetic-device-a-caller", displayName: "Synthetic"),
              target: .credential(id: id, fields: nil), duration: .always)
    }

    private func fixture(name: String, mixed: Bool) throws -> MissingSyncFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-missing-pair-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixture = MissingSyncFixture(directory: directory, namespace: "synthetic-pair-" + name)
        let meta = MetaStore(directory: directory, integrityIO: fixture.integrity)
        let credential = Credential(label: "Synthetic", notes: "Synthetic history remains", links: [],
            fields: ["key": .init(secret: true)], security: .strict, created: "2026-11-04", updated: "2026-11-04")
        try meta.save(.init(storeInitialized: true, credentials: mixed ? ["complete": credential, "partial": credential] : [:]))
        fixture.values.blob = try CloudVaultSnapshot.encode(KeychainBlobStore.Blob(version: 1,
            credentials: mixed ? ["complete": ["key": "synthetic-present", "orphan": "synthetic-local-only"],
                                  "orphan-group": ["key": "synthetic-unreferenced"]] : [:]))
        return fixture
    }
}

private struct MissingSyncFixture {
    let directory: URL
    let namespace: String
    let integrity = FakeKeychainIO(), values = FakeKeychainIO(), grants = FakeKeychainIO()
    let journalIO = FakeKeychainIO(), stateIO = FakeKeychainIO()
    let journalMarker = TestJournalMarker(), stateMarker = TestJournalMarker()

    func open(_ cloud: MissingSyncCloud) -> (local: LocalVaultCommitCoordinator, engine: CloudSyncCoordinator, state: CloudSyncStateStore) {
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values, integrityIO: integrity,
            approvalsIO: grants, namespace: namespace)
        let journal = LocalVaultJournal(io: journalIO, marker: journalMarker, namespace: namespace)
        let local = LocalVaultCommitCoordinator(adapter: adapter, journal: journal,
            gate: VaultAccessGate { try journal.requireReady() })
        let state = CloudSyncStateStore(io: stateIO, marker: stateMarker, namespace: namespace)
        return (local, CloudSyncCoordinator(local: local, stateStore: state, makeTransport: { cloud }), state)
    }
}

private final class MissingSyncCloud: CloudSyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var head: CloudSyncRemote?
    private var writes = 0
    private let identity = CloudSyncBinding(container: "synthetic", environment: "Production", accountID: "synthetic-pair")
    var hasOutstandingOperation: Bool { false }
    var uploads: Int { lock.withLock { writes } }
    var snapshot: CloudVaultSnapshot? { lock.withLock { head?.snapshot } }
    func binding() async throws -> CloudSyncBinding { identity }
    func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote? {
        guard binding == identity else { throw CloudSyncError.accountChanged }
        return lock.withLock { head }
    }
    func upload(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding) async throws {
        try lock.withLock {
            guard binding == identity else { throw CloudSyncError.accountChanged }
            guard pending.expectedRevisionID == head?.revisionID,
                  pending.expectedChangeToken == head?.changeToken else { throw CloudSyncError.conflict }
            head = .init(revisionID: pending.id, snapshot: try pending.snapshot(),
                changeToken: Data(pending.id.uuidString.utf8))
            writes += 1
        }
    }
    func cancel() {}
    func withCurrentBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T {
        guard binding == identity else { throw CloudSyncError.accountChanged }
        return try effect()
    }
}
