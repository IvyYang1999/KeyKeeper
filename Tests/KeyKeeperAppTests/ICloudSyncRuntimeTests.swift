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

    func testAccountChangePausesAndManualRetryReloadsBeforeEnabling() async throws {
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

    /// 【曾经的 bug】2026-11-08 yyt：「每次都要我手动在这台电脑上点击重试，然后再在另一台电脑上重试并同步」。
    /// Any failure used to pause until a click. Now a pause that a retry can clear retries by itself:
    /// 30 s, 2 min, 10 min, then every 15 min (shortened here), doing what the Retry button does.
    func test曾经的Bug临时失败会自己重试而且越等越久() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.unavailable, .unavailable])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(),
                                        retryDelays: [10_000_000, 60_000_000])
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        let calls = await engine.calls
        XCTAssertEqual(calls, ["load", "sync", "load", "enable", "load", "enable"])
        let times = await engine.enableTimes
        XCTAssertGreaterThanOrEqual(times[1] - times[0], .milliseconds(60), "The second wait is the longer one")
        XCTAssertNil(runtime.state.nextRetry)
        XCTAssertNil(ICloudSyncSettingsCard.retryText(runtime.state))
        runtime.stopScheduling()
    }

    func testWhileWaitingTheCardSaysWhenItTriesAgain() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.unavailable])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), retryDelays: [60_000_000_000])
        await runtime.start()
        await eventually { runtime.state.nextRetry != nil }
        XCTAssertEqual(runtime.state.phase, .paused)
        XCTAssertEqual(runtime.state.issue, .networkUnavailable)
        let next = try XCTUnwrap(runtime.state.nextRetry)
        XCTAssertEqual(next.timeIntervalSinceNow, 60, accuracy: 5)
        let time = next.formatted(.dateTime.hour().minute().locale(AppL10n.locale))
        XCTAssertEqual(ICloudSyncSettingsCard.retryText(runtime.state), L("Will try again automatically at \(time)."))
        runtime.stopScheduling()
        XCTAssertNil(runtime.state.nextRetry)
    }

    /// 【曾经的 bug】同上：收到「iCloud 账号变了」的通知就一直停着，其实大多还是同一个账号。The automatic retry
    /// re-reads the account ID and compares it with the bound one inside `enable()`; the same account resumes.
    func test曾经的Bug账号通知后自己核对同一账号就恢复() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: engine, center: center, retryDelays: [10_000_000])
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        center.post(name: .CKAccountChanged, object: nil)
        await eventually { await engine.calls.contains("account") }
        await eventually { await engine.calls.last == "enable" }
        await eventually { runtime.state.phase == .ready }
        let calls = await engine.calls
        let account = try XCTUnwrap(calls.firstIndex(of: "account"))
        XCTAssertEqual(Array(calls.dropFirst(account + 1)), ["load", "enable"])
        runtime.stopScheduling()
    }

    /// A different account keeps failing that comparison: it stays paused, keeps only re-checking, and
    /// never runs a sync cycle or replays an upload. (The no-read/no-write proof is the integration test.)
    func testDifferentAccountStaysPausedAndOnlyRechecks() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        let center = NotificationCenter()
        let runtime = ICloudSyncRuntime(engine: engine, center: center, retryDelays: [5_000_000])
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        await engine.queue(Array(repeating: .accountChanged, count: 50))
        center.post(name: .CKAccountChanged, object: nil)
        await eventually { await engine.calls.filter { $0 == "enable" }.count >= 3 }
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "sync" }.count, 1, "Only the startup cycle")
        XCTAssertFalse(calls.contains("retryPending"))
        XCTAssertTrue(runtime.state.phase == .paused || runtime.state.phase == .syncing)
        runtime.stopScheduling()
    }

    func testUnconfirmedUploadIsOnlyRecheckedNeverResentAutomatically() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.pendingUpload, .pendingUpload, .pendingUpload])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), retryDelays: [10_000_000])
        await runtime.start()
        await eventually { runtime.state.phase == .ready }
        let calls = await engine.calls
        XCTAssertEqual(calls.filter { $0 == "enable" }.count, 3)
        XCTAssertFalse(calls.contains("retryPending"), "Re-sending stays behind the person's Check and retry")
        var waiting = ICloudSyncPresentation(phase: .paused, enabled: true, issue: .pendingUpload)
        waiting.nextRetry = Date()
        let time = Date().formatted(.dateTime.hour().minute().locale(AppL10n.locale))
        XCTAssertEqual(ICloudSyncSettingsCard.retryText(waiting), L("Will check again automatically at \(time)."))
        runtime.stopScheduling()
    }

    func testPausesThatNeedThePersonDoNotRetryByThemselves() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.unsupportedSnapshotVersion])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), retryDelays: [2_000_000])
        await runtime.start()
        await eventually { runtime.state.issue == .unsupportedSnapshotVersion }
        try await Task.sleep(nanoseconds: 40_000_000)
        let calls = await engine.calls
        XCTAssertEqual(calls, ["load", "sync"])
        XCTAssertNil(runtime.state.nextRetry)
        runtime.stopScheduling()

        func retries(_ phase: ICloudSyncPresentation.Phase, _ issue: ICloudSyncPresentation.Issue?, enabled: Bool = true) -> Bool {
            ICloudSyncPresentation(phase: phase, enabled: enabled, issue: issue).retriesAutomatically
        }
        for issue: ICloudSyncPresentation.Issue in [.accountChanged, .networkUnavailable, .storageUnavailable,
                                                    .incompleteVault, .pendingUpload, .stale] {
            XCTAssertTrue(retries(.paused, issue), "\(issue)")
            XCTAssertEqual(retries(.paused, issue, enabled: false), issue == .storageUnavailable,
                "Not shown as on: only a record that could not be read is read again: \(issue)")
        }
        for issue: ICloudSyncPresentation.Issue in [.identityUnavailable, .unsupportedMigration, .unsupportedSnapshotVersion] {
            XCTAssertFalse(retries(.paused, issue), "\(issue)")
        }
        XCTAssertFalse(retries(.conflict, .stale), "Conflicts wait for the person's choices")
        XCTAssertFalse(retries(.unavailable, .storageUnavailable))
        XCTAssertFalse(retries(.paused, nil))
    }

    func testTurningSyncOffCancelsTheScheduledRetry() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.unavailable])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), retryDelays: [40_000_000])
        await runtime.start()
        await eventually { runtime.state.nextRetry != nil }
        runtime.perform(.disable)
        await eventually { runtime.state.phase == .off }
        XCTAssertNil(runtime.state.nextRetry)
        try await Task.sleep(nanoseconds: 90_000_000)
        let calls = await engine.calls
        XCTAssertFalse(calls.contains("enable"))
        runtime.stopScheduling()
    }

    func testWakeOrNetworkBackRetriesAPauseNowAndSyncsARunningOne() async throws {
        let engine = RecordingSyncDriver(enabled: true)
        await engine.queue([.unavailable])
        let runtime = ICloudSyncRuntime(engine: engine, center: NotificationCenter(), retryDelays: [60_000_000_000])
        await runtime.start()
        await eventually { runtime.state.nextRetry != nil }
        runtime.systemResumed()
        await eventually { runtime.state.phase == .ready }
        var calls = await engine.calls
        XCTAssertEqual(calls, ["load", "sync", "load", "enable"])
        runtime.systemResumed()
        await eventually { await engine.calls.count == 5 }
        calls = await engine.calls
        XCTAssertEqual(calls.last, "sync", "After sleep a running sync catches up on the other Mac's changes")
        runtime.stopScheduling()
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
    var enableTimes: [ContinuousClock.Instant] = []
    /// Each enable/sync takes the next outcome; none left (or nil) succeeds.
    private var outcomes: [CloudSyncError?] = []
    init(enabled: Bool = false) { status = .init(enabled: enabled, phase: enabled ? .ready : .off) }
    func queue(_ next: [CloudSyncError?]) { outcomes = next }
    private func finish() {
        if !outcomes.isEmpty, let error = outcomes.removeFirst() { status.phase = .paused; status.error = error }
        else { status.phase = .synced; status.error = nil }
    }
    func load() { calls.append("load") }
    func enable() { calls.append("enable"); enableTimes.append(.now); status.enabled = true; finish() }
    func disable() { calls.append("disable"); status.enabled = false; status.phase = .off }
    func syncNow() { calls.append("sync"); finish() }
    func accountChanged() { calls.append("account"); status.phase = .paused; status.error = .accountChanged }
    func retryPendingUpload() { calls.append("retryPending") }
    func resolve(reviewID: UUID, choices: [String: CloudSyncChoice]) { calls.append("resolve") }
}
