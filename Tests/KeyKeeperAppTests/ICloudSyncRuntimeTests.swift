import XCTest
import CloudKit
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class ICloudSyncRuntimeTests: XCTestCase {
    func testInitializationAndDefaultOffStartNeverOptIn() async throws {
        let engine = RecordingSyncDriver()
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: engine, center: center, interval: 5_000_000)
        var calls = await engine.calls
        XCTAssertTrue(calls.isEmpty)
        await runtime.start()
        center.post(name: .credentialsChanged, object: nil)
        try await Task.sleep(nanoseconds: 20_000_000)
        calls = await engine.calls
        XCTAssertEqual(calls, ["load"])
        XCTAssertFalse(runtime.state.enabled)
        runtime.stopScheduling()
    }

    func testOnlyExplicitEnableOptsInAndDisableRemainsAvailable() async {
        let engine = RecordingSyncDriver()
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter())
        await runtime.start()
        runtime.perform(.enable)
        await eventually { runtime.state.phase == .ready && runtime.state.enabled }
        var calls = await engine.calls
        XCTAssertTrue(calls.contains("enable"))
        runtime.perform(.disable)
        await eventually { runtime.state.phase == .off }
        calls = await engine.calls
        XCTAssertTrue(calls.contains("disable"))
        XCTAssertFalse(runtime.state.enabled)
        runtime.stopScheduling()
    }

    func testCoalescesLocalChangesIgnoresOwnApplyAndStopsObservers() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: engine, center: center, debounce: 15_000_000)
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        let initial = await engine.calls.filter { $0 == "sync" }.count
        XCTAssertEqual(initial, 1, "Persisted opt-in resumes one startup cycle")
        center.post(name: .credentialsChanged, object: runtime.ownChange)
        try await Task.sleep(nanoseconds: 25_000_000)
        var count = await engine.calls.filter { $0 == "sync" }.count
        XCTAssertEqual(count, initial)
        for _ in 0..<5 { center.post(name: .credentialsChanged, object: nil) }
        await eventually { await engine.calls.filter { $0 == "sync" }.count == initial + 1 }
        runtime.stopScheduling()
        center.post(name: .credentialsChanged, object: nil)
        try await Task.sleep(nanoseconds: 25_000_000)
        count = await engine.calls.filter { $0 == "sync" }.count
        XCTAssertEqual(count, initial + 1)
    }

    func testPeriodicWorkStopsAfterShutdown() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), interval: 8_000_000)
        await runtime.start()
        await eventually { await engine.calls.filter { $0 == "sync" }.count >= 2 }
        runtime.stopScheduling()
        let count = await engine.calls.count
        try await Task.sleep(nanoseconds: 30_000_000)
        let after = await engine.calls.count
        XCTAssertEqual(count, after)
    }

    func testAccountChangePausesUntilExplicitRetryAndReloadsBeforeEnabling() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: engine, center: center, interval: 5_000_000)
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        center.post(name: .CKAccountChanged, object: nil)
        await eventually { runtime.state.issue == .accountChanged }
        let pausedCount = await engine.calls.count
        try await Task.sleep(nanoseconds: 20_000_000)
        var calls = await engine.calls
        XCTAssertEqual(calls.count, pausedCount)
        runtime.perform(.retry)
        await eventually { runtime.state.phase == .ready }
        calls = await engine.calls
        let account = try XCTUnwrap(calls.firstIndex(of: "account"))
        XCTAssertEqual(Array(calls.dropFirst(account + 1).prefix(2)), ["load", "enable"])
        runtime.stopScheduling()
    }

    func testPresentationIncludesOnlyConflictMetadataAndFixedIssue() {
        let id = UUID(), timestamp = Date(timeIntervalSince1970: 100)
        let status = CloudSyncStatus(enabled: true, phase: .conflicts, lastSuccess: timestamp,
            conflicts: [.init(credentialID: "fixture", title: "Synthetic label", localDeleted: false, remoteDeleted: true)],
            reviewID: id, error: .localChanged)
        let presentation = ICloudSyncRuntime.presentation(status)
        XCTAssertEqual(presentation.phase, .conflict)
        XCTAssertEqual(presentation.issue, .stale)
        XCTAssertEqual(presentation.lastSuccess, timestamp)
        XCTAssertEqual(presentation.review?.id, id)
        XCTAssertEqual(presentation.review?.rows.first?.label, "Synthetic label")
        XCTAssertEqual(presentation.review?.rows.first?.localExists, true)
        XCTAssertEqual(presentation.review?.rows.first?.remoteExists, false)
    }

    func testLocalDataFailureExplainsVerificationInsteadOfNetworkOrMissingValues() {
        let state = ICloudSyncRuntime.presentation(.init(phase: .paused, error: .localDataUnavailable))
        XCTAssertEqual(state.issue, .incompleteVault)
        XCTAssertEqual(ICloudSyncSettingsCard.issueText(.incompleteVault),
            L("Credential data could not be verified. Existing data was kept. Restore storage access before retrying."))
    }

    func testPresentationCarriesMissingCountsAndSafeChoicesWithoutChangingReadyState() {
        let state = ICloudSyncRuntime.presentation(.init(enabled: true, phase: .synced,
            conflicts: [.init(credentialID: "synthetic", title: "Synthetic", localDeleted: false,
                              remoteDeleted: false, canChooseLocal: false, canChooseRemote: true)],
            reviewID: UUID(), missingCredentialCount: 1, missingFieldCount: 2))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertNil(state.issue)
        XCTAssertEqual(state.missingCredentialCount, 1)
        XCTAssertEqual(state.missingFieldCount, 2)
        XCTAssertEqual(state.review?.rows.first?.canChooseLocal, false)
        XCTAssertEqual(state.review?.rows.first?.canChooseRemote, true)
        let unchecked = ICloudSyncRuntime.presentation(.init())
        XCTAssertNil(unchecked.missingCredentialCount)
        XCTAssertNil(unchecked.missingFieldCount)
        let repaired = ICloudSyncRuntime.presentation(.init(enabled: true, phase: .synced,
            missingCredentialCount: 0, missingFieldCount: 0))
        XCTAssertEqual(repaired.missingCredentialCount, 0)
        XCTAssertEqual(repaired.missingFieldCount, 0)
    }

    func testUnsupportedSnapshotAsksForUpgradeInsteadOfNetworkRetry() {
        let state = ICloudSyncRuntime.presentation(.init(phase: .paused, error: .unsupportedSnapshotVersion))
        XCTAssertEqual(state.issue, .unsupportedSnapshotVersion)
        XCTAssertEqual(ICloudSyncSettingsCard.issueText(.unsupportedSnapshotVersion),
            L("This version of KeyKeeper cannot read the sync data. Update KeyKeeper on this Mac before retrying."))
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

private actor RecordingSyncDriver: ICloudSyncDriving {
    var status: CloudSyncStatus
    var calls: [String] = []
    init(enabled: Bool = false) { status = .init(enabled: enabled, phase: enabled ? .ready : .off) }
    func load() { calls.append("load") }
    func enable() { calls.append("enable"); status.enabled = true; status.phase = .synced; status.error = nil }
    func disable() { calls.append("disable"); status.enabled = false; status.phase = .off }
    func syncNow() { calls.append("sync"); status.phase = .synced }
    func accountChanged() { calls.append("account"); status.phase = .paused; status.error = .accountChanged }
    func retryPendingUpload() { calls.append("retryPending") }
    func resolve(reviewID: UUID, choices: [String: CloudSyncChoice]) { calls.append("resolve") }
}
