import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// UI actions reach the real coordinator, journal, metadata MAC and local blob adapter.
/// Only Keychain IO and CloudKit transport are replaced; all data here is synthetic.
@MainActor
final class ICloudSyncRuntimeIntegrationTests: XCTestCase {
    func testOptInRemoteApplyAndDisableKeepLocalDataAndGrantsLocal() async throws {
        let f = try fixture()
        let beforeValues = f.values.blob, beforeGrants = f.grants.blob
        await f.runtime.start()
        XCTAssertEqual(f.values.blob, beforeValues)
        XCTAssertEqual(f.values.ordinaryReads, 0)
        XCTAssertEqual(f.cloud.factoryCount, 0)
        f.runtime.perform(.enable)
        await eventually { f.runtime.state.phase == .ready }
        XCTAssertTrue(f.runtime.state.enabled)
        XCTAssertEqual(f.cloud.uploadCount, 1)
        XCTAssertNotNil(try f.stateStore.load()?.baseData)
        XCTAssertEqual(f.grants.blob, beforeGrants)
        let initial = try f.local.capture().snapshot
        var remote = try XCTUnwrap(initial.credentials["fixture"])
        remote.metadata.notes = "Synthetic edit on second Mac"
        remote.secrets["key"] = "synthetic-from-second-mac"
        f.cloud.setRemote(try .init(credentials: ["fixture": remote]))
        f.runtime.perform(.syncNow)
        await eventually { f.runtime.state.phase == .ready }
        XCTAssertEqual(try f.meta.loadForUse().credentials["fixture"]?.notes, "Synthetic edit on second Mac")
        XCTAssertEqual(try f.local.capture().snapshot.credentials["fixture"]?.secrets["key"], "synthetic-from-second-mac")
        XCTAssertEqual(f.grants.blob, beforeGrants, "No remote caller grants enter this Mac")
        let keptValues = f.values.blob, keptSnapshot = try f.local.capture().snapshot.encoded()
        f.runtime.perform(.disable)
        await eventually { f.runtime.state.phase == .off }
        XCTAssertFalse(try XCTUnwrap(f.stateStore.load()).enabled)
        XCTAssertEqual(f.values.blob, keptValues)
        XCTAssertEqual(try f.local.capture().snapshot.encoded(), keptSnapshot)
        XCTAssertNotNil(f.cloud.remoteSnapshot)
        f.runtime.stopScheduling()
    }

    func testDisableWhileNativeFetchWaitsCannotPublishLateData() async throws {
        let f = try fixture(), gate = RuntimeFetchGate()
        f.cloud.gate = gate
        await f.runtime.start()
        f.runtime.perform(.enable)
        await eventually { await gate.entered }
        XCTAssertTrue(f.runtime.state.enabled, "Turn off remains available during initial enable")
        f.runtime.perform(.disable)
        await eventually { f.runtime.state.phase == .off }
        XCTAssertFalse(f.runtime.state.enabled)
        await gate.release()
        await eventually { !(await f.coordinator.status).busy }
        XCTAssertFalse(f.runtime.state.enabled)
        XCTAssertEqual(f.cloud.uploadCount, 0)
        XCTAssertNil(try f.stateStore.load()?.baseData)
        f.runtime.stopScheduling()
    }

    func testDisableWriteFailureRetryPreservesOffIntentAndNeverReEnables() async throws {
        let f = try fixture()
        await f.runtime.start()
        f.runtime.perform(.enable)
        await eventually { f.runtime.state.phase == .ready }
        let created = f.cloud.factoryCount, uploads = f.cloud.uploadCount
        f.stateIO.failWrites = true
        f.runtime.perform(.disable)
        await eventually { f.runtime.state.phase == .paused && f.runtime.state.issue == .storageUnavailable }
        XCTAssertFalse(f.runtime.state.enabled, "UI retains the requested off intent although persistence failed")
        XCTAssertTrue(try XCTUnwrap(f.stateStore.load()).enabled, "Failure has not been misreported as durable success")
        f.stateIO.failWrites = false
        f.runtime.perform(.retry)
        await eventually { f.runtime.state.phase == .off }
        XCTAssertFalse(try XCTUnwrap(f.stateStore.load()).enabled)
        XCTAssertEqual(f.cloud.factoryCount, created)
        XCTAssertEqual(f.cloud.uploadCount, uploads)
        f.runtime.stopScheduling()
    }

    private func fixture() throws -> RuntimeFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-sync-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), grants = FakeKeychainIO(), stateIO = FakeKeychainIO()
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        let credential = Credential(label: "Synthetic runtime", notes: "", links: [], fields: ["key": .init(secret: true)],
            security: .strict, created: "2026-11-02", updated: "2026-11-02")
        try meta.save(.init(storeInitialized: true, credentials: ["fixture": credential]))
        values.blob = try JSONEncoder().encode(KeychainBlobStore.Blob(version: 1, credentials: ["fixture": ["key": "synthetic-original"]]))
        grants.blob = try JSONEncoder().encode(ApprovalDocument())
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values, integrityIO: integrity,
            approvalsIO: grants, namespace: "runtime-fixture")
        let journal = LocalVaultJournal(io: FakeKeychainIO(), marker: RuntimeMarker(), namespace: "runtime-fixture")
        let local = LocalVaultCommitCoordinator(adapter: adapter, journal: journal, gate: VaultAccessGate { try journal.requireReady() })
        let stateStore = CloudSyncStateStore(io: stateIO, marker: RuntimeMarker(), namespace: "runtime-fixture")
        let cloud = RuntimeCloud()
        let coordinator = CloudSyncCoordinator(local: local, stateStore: stateStore, makeTransport: {
            cloud.constructed(); return cloud
        })
        let runtime = ICloudSyncRuntime(engine: coordinator, center: NotificationCenter())
        return .init(runtime: runtime, coordinator: coordinator, local: local, meta: meta, values: values,
                     grants: grants, stateIO: stateIO, stateStore: stateStore, cloud: cloud)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line,
                            _ predicate: () async -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Condition did not become true within one second", file: file, line: line)
    }
}

private struct RuntimeFixture {
    let runtime: ICloudSyncRuntime
    let coordinator: CloudSyncCoordinator
    let local: LocalVaultCommitCoordinator
    let meta: MetaStore
    let values: FakeKeychainIO
    let grants: FakeKeychainIO
    let stateIO: FakeKeychainIO
    let stateStore: CloudSyncStateStore
    let cloud: RuntimeCloud
}
private final class RuntimeMarker: LocalVaultJournalMarker, @unchecked Sendable {
    var created = false
    func wasCreated() throws -> Bool { created }
    func markCreated() throws { created = true }
}
private actor RuntimeFetchGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
private final class RuntimeCloud: CloudSyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var remote: CloudSyncRemote?
    private var constructions = 0, uploads = 0
    var gate: RuntimeFetchGate?
    var hasOutstandingOperation: Bool { false }
    var factoryCount: Int { lock.withLock { constructions } }
    var uploadCount: Int { lock.withLock { uploads } }
    var remoteSnapshot: CloudVaultSnapshot? { lock.withLock { remote?.snapshot } }
    func constructed() { lock.withLock { constructions += 1 } }
    func binding() async throws -> CloudSyncBinding { .init(container: "synthetic", environment: "Production", accountID: "synthetic") }
    func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote? {
        if let gate { await gate.wait() }
        return lock.withLock { remote }
    }
    func upload(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding) async throws {
        try lock.withLock {
            uploads += 1
            remote = .init(revisionID: pending.id, snapshot: try pending.snapshot(), changeToken: Data("synthetic-token".utf8))
        }
    }
    func setRemote(_ snapshot: CloudVaultSnapshot) {
        lock.withLock { remote = .init(revisionID: UUID(), snapshot: snapshot, changeToken: Data("synthetic-change".utf8)) }
    }
    func cancel() {}
    func withCurrentBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T { try effect() }
}
