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

    func testMixedRecordsSyncCountsAndRemoteRepairPreserveRecordsAndDeviceLocalGrants() async throws {
        let f = try fixture(withMissingRecord: true)
        defer { f.runtime.stopScheduling() }
        let approvals = ApprovalStore(io: f.grants)
        for id in ["fixture", "missing"] {
            try approvals.add(.init(subject: .init(fingerprint: "synthetic-caller", displayName: "Synthetic"),
                target: .credential(id: id, fields: nil), duration: .always))
        }
        let beforeValues = f.values.blob, beforeGrants = f.grants.blob
        await f.runtime.start()
        XCTAssertNil(f.runtime.state.missingCredentialCount, "Off does not inspect values to populate counts")
        XCTAssertNil(f.runtime.state.missingFieldCount)
        XCTAssertEqual(f.values.blob, beforeValues)
        XCTAssertEqual(f.values.ordinaryReads, 0)
        XCTAssertEqual(f.cloud.factoryCount, 0)

        f.runtime.perform(.enable)
        await eventually { f.runtime.state.phase == .ready && f.runtime.state.missingFieldCount == 2 }
        XCTAssertTrue(f.runtime.state.enabled)
        XCTAssertEqual(f.runtime.state.missingCredentialCount, 1)
        XCTAssertNil(f.runtime.state.issue)
        XCTAssertEqual(f.grants.blob, beforeGrants, "Publishing unchanged local records cannot import or revoke grants")
        let initial = try XCTUnwrap(f.cloud.remoteSnapshot)
        XCTAssertEqual(Set(initial.credentials.keys), ["fixture", "missing"])
        XCTAssertEqual(initial.credentials["missing"]?.missingSecretFields, ["key", "secondary"])
        XCTAssertEqual(initial.credentials["fixture"]?.secrets["key"], "synthetic-original")

        var records = initial.credentials
        records["missing"]?.secrets["key"] = "synthetic-repaired-first"
        records["missing"]?.missingSecretFields = ["secondary"]
        f.cloud.setRemote(try .init(credentials: records))
        f.runtime.perform(.syncNow)
        await eventually { f.runtime.state.phase == .ready && f.runtime.state.missingFieldCount == 1 }
        XCTAssertEqual(f.runtime.state.missingCredentialCount, 1)
        XCTAssertTrue(try approvals.hasApprovals(forCredential: "fixture"))
        XCTAssertFalse(try approvals.hasApprovals(forCredential: "missing"), "A repaired value requires new approval on this Mac")
        XCTAssertEqual(Set(try f.meta.loadForUse().credentials.keys), ["fixture", "missing"])

        records["missing"]?.secrets["secondary"] = "synthetic-repaired-second"
        records["missing"]?.missingSecretFields = []
        f.cloud.setRemote(try .init(credentials: records))
        f.runtime.perform(.syncNow)
        await eventually { f.runtime.state.phase == .ready && f.runtime.state.missingFieldCount == 0 }
        XCTAssertEqual(f.runtime.state.missingCredentialCount, 0)
        let repaired = try f.local.capture().snapshot
        XCTAssertEqual(Set(repaired.credentials.keys), ["fixture", "missing"])
        XCTAssertEqual(repaired.credentials["missing"]?.secrets,
                       ["key": "synthetic-repaired-first", "secondary": "synthetic-repaired-second"])
        XCTAssertEqual(try approvals.all().count, 1, "Remote synchronization never creates caller grants")

        f.runtime.stopScheduling()
        let cloud = f.cloud
        let reloadedCoordinator = CloudSyncCoordinator(local: f.local, stateStore: f.stateStore,
                                                       makeTransport: { cloud.constructed(); return cloud })
        let reloaded = ICloudSyncRuntime(engine: reloadedCoordinator, center: NotificationCenter())
        defer { reloaded.stopScheduling() }
        await reloaded.start()
        await eventually { reloaded.state.phase == .ready && reloaded.state.missingFieldCount == 0 }
        XCTAssertEqual(reloaded.state.missingCredentialCount, 0)
        XCTAssertEqual(try f.local.capture().snapshot.encoded(), try repaired.encoded())
        XCTAssertEqual(try approvals.all().count, 1)
    }

    /// 【曾经的 bug】2026-11-08 yyt：同步总要手动点「重试」。一次连不上 iCloud 就停住，现在自己接着试。
    func test曾经的Bug连不上iCloud之后不用点也会自己同步上() async throws {
        let f = try fixture(retryDelays: [5_000_000])
        await f.runtime.start()
        f.cloud.failNextFetches = 2
        f.runtime.perform(.enable)
        await eventually { f.runtime.state.phase == .ready && f.cloud.uploadCount == 1 }
        XCTAssertEqual(f.cloud.failNextFetches, 0, "Both failures were met and retried past")
        XCTAssertNil(f.runtime.state.issue)
        XCTAssertNotNil(try f.stateStore.load()?.baseData)
        XCTAssertNotNil(try f.stateStore.load()?.lastSuccess)
        f.runtime.stopScheduling()
    }

    /// 【曾经的 bug】同上：「账号已更改」的暂停会存下来，重启也不消，只能点。Now the automatic retry
    /// re-reads the account ID. A different account stays paused and touches nothing in iCloud;
    /// the same account coming back resumes by itself.
    func test曾经的Bug换了账号一直停着且不读不写换回同一账号自己恢复() async throws {
        let f = try fixture(retryDelays: [5_000_000])
        await f.runtime.start()
        f.runtime.perform(.enable)
        await eventually { f.runtime.state.phase == .ready }
        let uploads = f.cloud.uploadCount, fetches = f.cloud.fetchCount
        let remote = try XCTUnwrap(f.cloud.remoteSnapshot).encoded()
        let bound = try XCTUnwrap(f.stateStore.load()?.binding)

        f.cloud.accountID = "synthetic-other-account"
        f.center.post(name: .CKAccountChanged, object: nil)
        let checks = f.cloud.bindingCount
        await eventually { f.cloud.bindingCount >= checks + 3 }
        XCTAssertEqual(f.runtime.state.issue, .accountChanged)
        XCTAssertEqual(f.cloud.fetchCount, fetches, "Nothing is read from the other account")
        XCTAssertEqual(f.cloud.uploadCount, uploads, "Nothing is written to the other account")
        XCTAssertEqual(try XCTUnwrap(f.cloud.remoteSnapshot).encoded(), remote)
        XCTAssertEqual(try f.stateStore.load()?.binding, bound)
        XCTAssertEqual(try f.stateStore.load()?.accountChangePaused, true)

        f.cloud.accountID = "synthetic"
        await eventually { f.runtime.state.phase == .ready }
        XCTAssertNil(f.runtime.state.issue)
        XCTAssertEqual(try f.stateStore.load()?.accountChangePaused, false)
        XCTAssertEqual(try f.stateStore.load()?.binding, bound)
        f.runtime.stopScheduling()
    }

    private func fixture(withMissingRecord: Bool = false,
                         retryDelays: [UInt64] = ICloudSyncRuntime.defaultRetryDelays) throws -> RuntimeFixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-sync-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), grants = FakeKeychainIO(), stateIO = FakeKeychainIO()
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        let credential = Credential(label: "Synthetic runtime", notes: "", links: [], fields: ["key": .init(secret: true)],
            security: .strict, created: "2026-11-02", updated: "2026-11-02")
        var records = ["fixture": credential]
        if withMissingRecord {
            var missing = credential
            missing.label = "Synthetic missing values"
            missing.fields["secondary"] = .init(secret: true)
            records["missing"] = missing
        }
        try meta.save(.init(storeInitialized: true, credentials: records))
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
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: coordinator, center: center, retryDelays: retryDelays)
        return .init(runtime: runtime, coordinator: coordinator, local: local, meta: meta, values: values,
                     grants: grants, stateIO: stateIO, stateStore: stateStore, cloud: cloud, center: center)
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
    let center: NotificationCenter
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
    private var constructions = 0, uploads = 0, fetches = 0, bindings = 0, failures = 0
    private var account = "synthetic"
    var gate: RuntimeFetchGate?
    var hasOutstandingOperation: Bool { false }
    var factoryCount: Int { lock.withLock { constructions } }
    var uploadCount: Int { lock.withLock { uploads } }
    var fetchCount: Int { lock.withLock { fetches } }
    var bindingCount: Int { lock.withLock { bindings } }
    /// Synthetic "iCloud could not be reached" for the next N fetches.
    var failNextFetches: Int {
        get { lock.withLock { failures } }
        set { lock.withLock { failures = newValue } }
    }
    var accountID: String {
        get { lock.withLock { account } }
        set { lock.withLock { account = newValue } }
    }
    var remoteSnapshot: CloudVaultSnapshot? { lock.withLock { remote?.snapshot } }
    func constructed() { lock.withLock { constructions += 1 } }
    func binding() async throws -> CloudSyncBinding {
        lock.withLock {
            bindings += 1
            return .init(container: "synthetic", environment: "Production", accountID: account)
        }
    }
    func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote? {
        if let gate { await gate.wait() }
        return try lock.withLock {
            guard binding.accountID == account else { throw CloudSyncError.accountChanged }
            if failures > 0 { failures -= 1; throw CloudSyncError.unavailable }
            fetches += 1
            return remote
        }
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
