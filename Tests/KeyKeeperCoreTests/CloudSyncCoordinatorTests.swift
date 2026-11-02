import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class CloudSyncCoordinatorTests: XCTestCase {
    func testDefaultOffNeverCreatesTransportOrReadsValues() async throws {
        let h = try SyncHarness()
        await h.engine.load(); await h.engine.syncNow()
        let status = await h.engine.status
        XCTAssertEqual(status.phase, .off)
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(h.local.reads, 0)
        XCTAssertEqual(h.factory.calls, 0)
        XCTAssertEqual(h.cloud.uploads, 0)
    }

    func testFirstCyclePersistsPendingBeforeUploadAndConfirmsCompleteSnapshot() async throws {
        let h = try SyncHarness()
        h.cloud.beforeUpload = {
            XCTAssertNotNil(h.store.state?.pending)
            XCTAssertNil(h.store.state?.transition)
            XCTAssertGreaterThan(h.local.applies, 0)
        }
        await h.engine.enable()
        let status = await h.engine.status
        XCTAssertEqual(status.phase, .synced)
        XCTAssertNil(status.error)
        XCTAssertEqual(h.cloud.uploads, 1)
        XCTAssertNil(h.store.state?.pending)
        XCTAssertEqual(h.store.state?.baseData, try h.local.value.encoded())
        XCTAssertEqual(try h.cloud.remote?.snapshot.encoded(), try h.local.value.encoded())
    }

    func testMissingOrCorruptInitializedStateFailsClosed() throws {
        let io = FakeKeychainIO(), marker = TestJournalMarker()
        let store = CloudSyncStateStore(io: io, marker: marker, namespace: "fixture")
        XCTAssertNil(try store.load())
        try store.save(.init())
        XCTAssertFalse(try XCTUnwrap(store.load()).enabled)
        XCTAssertTrue(marker.created)
        io.blob = nil
        XCTAssertThrowsError(try store.load())
        io.blob = Data("not state".utf8)
        XCTAssertThrowsError(try store.load())
    }
    func testUncertainSuccessfulUploadIsReadBackWithoutAnotherWrite() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable; h.cloud.commitThenFail = true
        await h.engine.enable()
        XCTAssertNotNil(h.store.state?.pending)
        XCTAssertEqual(h.cloud.uploads, 1)
        h.cloud.failUpload = nil
        await h.engine.syncNow()
        let status = await h.engine.status
        XCTAssertEqual(status.phase, .synced)
        XCTAssertNil(h.store.state?.pending)
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testCompetingIdenticalPublicationReconcilesCASAndUnknownResultsWithoutReplay() async throws {
        for error in [CloudSyncError.conflict, .unavailable] {
            let h = try SyncHarness()
            if error == .conflict {
                // Another Mac wins the actual expected-head check with identical content.
                h.cloud.beforeUpload = { h.cloud.setRemote(h.local.value) }
            } else {
                // Our write committed, another Mac then published the same content,
                // but our callback reported an unknown result.
                h.cloud.failUpload = error; h.cloud.commitThenFail = true
                h.cloud.afterUpload = { h.cloud.setRemote(h.local.value) }
            }
            await h.engine.enable()
            let pendingID = try XCTUnwrap(h.store.state?.pending?.id)
            XCTAssertNotEqual(h.cloud.remote?.revisionID, pendingID)
            let expected = try XCTUnwrap(h.cloud.remote).snapshot.encoded()
            await h.engine.syncNow()
            let result = await h.engine.status
            XCTAssertEqual(result.phase, .synced)
            XCTAssertTrue(result.conflicts.isEmpty)
            XCTAssertNil(result.reviewID)
            XCTAssertNil(h.store.state?.pending)
            XCTAssertEqual(h.store.state?.baseData, expected)
            XCTAssertEqual(h.cloud.uploads, 1)
            await h.engine.disable(); await h.engine.enable()
            let resumed = await h.engine.status
            XCTAssertEqual(resumed.phase, .synced)
            XCTAssertEqual(h.cloud.uploads, 1)
        }
    }

    func testDifferentPublicationOnImmediateReadbackReconcilesOnlyUnchangedLocal() async throws {
        for changed in [false, true] {
            let h = try SyncHarness()
            h.cloud.afterUpload = {
                h.cloud.setRemote(h.local.value)
                if changed { try h.local.change(syncSnapshot("newer")) }
            }
            await h.engine.enable()
            if changed { await h.engine.syncNow() }
            let result = await h.engine.status
            XCTAssertEqual(h.cloud.uploads, 1)
            if changed {
                XCTAssertEqual(result.phase, .conflicts)
                XCTAssertEqual(result.conflicts.map(\.credentialID), ["fixture"])
                XCTAssertNotNil(h.store.state?.pending)
                XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("newer").encoded())
            } else {
                XCTAssertEqual(result.phase, .synced)
                XCTAssertNil(h.store.state?.pending)
                XCTAssertEqual(h.store.state?.baseData, try h.cloud.remote?.snapshot.encoded())
            }
        }
    }

    func testCompetingPublicationDoesNotAcknowledgeChangedOrDeletedLocalData() async throws {
        for error in [CloudSyncError.conflict, .unavailable] {
            for deletion in [false, true] {
                let h = try SyncHarness()
                h.cloud.failUpload = error
                await h.engine.enable()
                h.cloud.setRemote(h.local.value)
                let current = try deletion ? CloudVaultSnapshot(credentials: [:]) : syncSnapshot("newer")
                try h.local.change(current)
                await h.engine.syncNow()
                let result = await h.engine.status
                XCTAssertEqual(result.phase, .conflicts)
                XCTAssertEqual(result.conflicts.map(\.credentialID), ["fixture"])
                XCTAssertEqual(result.conflicts.first?.localDeleted, deletion)
                XCTAssertNotNil(h.store.state?.pending)
                XCTAssertEqual(try h.local.value.encoded(), try current.encoded())
                XCTAssertEqual(h.cloud.uploads, 1)
            }
        }
    }

    func testExplicitPendingRetryRecognizesConvergedPublicationWithoutUpload() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        h.cloud.setRemote(h.local.value)
        await h.engine.retryPendingUpload()
        let result = await h.engine.status
        XCTAssertEqual(result.phase, .synced)
        XCTAssertNil(h.store.state?.pending)
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testConvergenceRejectsLocalRevisionChangeAtAcknowledgement() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        h.cloud.setRemote(h.local.value)
        let pending = h.store.state?.pending, base = h.store.state?.baseData
        h.local.beforeApply = { try h.local.change(syncSnapshot("newer")) }
        await h.engine.syncNow()
        let result = await h.engine.status
        XCTAssertEqual(result.error, .localChanged)
        XCTAssertEqual(h.store.state?.pending, pending)
        XCTAssertEqual(h.store.state?.baseData, base)
        XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("newer").encoded())
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testConvergenceRejectsSynchronousAccountInvalidationAfterFetch() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        h.cloud.setRemote(h.local.value)
        let pending = h.store.state?.pending, base = h.store.state?.baseData, applies = h.local.applies
        h.cloud.afterFetch = { h.cloud.invalidated = true }
        await h.engine.syncNow()
        let result = await h.engine.status
        XCTAssertEqual(result.error, .accountChanged)
        XCTAssertEqual(h.store.state?.pending, pending)
        XCTAssertEqual(h.store.state?.baseData, base)
        XCTAssertEqual(h.local.applies, applies)
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testMissingInitialHeadAfterDeletionWaitsForExplicitCurrentEmptyPublication() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        let original = try XCTUnwrap(h.store.state?.pending)
        try h.local.change(CloudVaultSnapshot(credentials: [:]))
        h.cloud.failUpload = nil
        await h.engine.syncNow()
        var result = await h.engine.status
        XCTAssertEqual(result.phase, .paused)
        XCTAssertEqual(result.error, .pendingUpload)
        XCTAssertTrue(result.canRetryPendingUpload)
        XCTAssertNil(result.reviewID)
        XCTAssertEqual(h.store.state?.pending, original)
        XCTAssertNil(h.store.state?.baseData)
        XCTAssertNil(h.store.state?.lastSuccess)
        XCTAssertNil(h.cloud.remote)
        XCTAssertEqual(h.cloud.uploads, 1)
        await h.engine.disable(); await h.engine.enable()
        result = await h.engine.status
        XCTAssertEqual(result.phase, .paused)
        XCTAssertTrue(result.canRetryPendingUpload)
        XCTAssertEqual(h.store.state?.pending, original)
        XCTAssertEqual(h.cloud.uploads, 1)
        h.cloud.beforeUpload = {
            XCTAssertNotEqual(h.store.state?.pending?.id, original.id)
            XCTAssertTrue((try? h.store.state?.pending?.snapshot().credentials.isEmpty) == true)
            XCTAssertNil(h.store.state?.transition)
        }
        await h.engine.retryPendingUpload()
        result = await h.engine.status
        XCTAssertEqual(result.phase, .synced)
        XCTAssertNil(h.store.state?.pending)
        XCTAssertEqual(h.cloud.uploads, 2)
        XCTAssertTrue(h.cloud.remote?.snapshot.credentials.isEmpty == true)
        XCTAssertTrue(h.local.value.credentials.isEmpty)
        XCTAssertEqual(h.store.state?.baseData, try h.local.value.encoded())
    }

    func testMissingInitialHeadRepeatedEmptyRetryKeepsPublicationIdentity() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        let originalID = try XCTUnwrap(h.store.state?.pending?.id)
        try h.local.change(CloudVaultSnapshot(credentials: [:]))
        await h.engine.retryPendingUpload()
        let emptyPending = try XCTUnwrap(h.store.state?.pending)
        XCTAssertNotEqual(emptyPending.id, originalID)
        XCTAssertTrue(try emptyPending.snapshot().credentials.isEmpty)
        await h.engine.syncNow()
        XCTAssertEqual(h.cloud.uploads, 2, "Automatic checks never replay")
        await h.engine.retryPendingUpload()
        XCTAssertEqual(h.store.state?.pending, emptyPending)
        XCTAssertEqual(h.cloud.uploads, 3)
        XCTAssertNil(h.cloud.remote)
        XCTAssertNil(h.store.state?.baseData)
    }

    func testPendingRecoveryMatrixNeverFabricatesEmptyReviews() async throws {
        for knownHead in [false, true] {
            for emptyLocal in [false, true] {
                for remoteKind in ["missing", "empty", "current"] {
                    let h = try SyncHarness()
                    if knownHead { await h.engine.enable(); try h.local.change(syncSnapshot("pending")) }
                    h.cloud.failUpload = .unavailable
                    if knownHead { await h.engine.syncNow() } else { await h.engine.enable() }
                    let pending = try XCTUnwrap(h.store.state?.pending)
                    try h.local.change(emptyLocal ? CloudVaultSnapshot(credentials: [:]) : syncSnapshot("current"))
                    if remoteKind == "missing" { h.cloud.remote = nil }
                    else { h.cloud.setRemote(try remoteKind == "empty" ? CloudVaultSnapshot(credentials: [:]) : syncSnapshot("current")) }
                    let uploads = h.cloud.uploads
                    await h.engine.syncNow()
                    let result = await h.engine.status
                    XCTAssertEqual(h.cloud.uploads, uploads)
                    if result.phase == .conflicts { XCTAssertFalse(result.conflicts.isEmpty) }
                    if remoteKind == "missing" && knownHead {
                        XCTAssertEqual(result.error, .unavailable)
                        XCTAssertFalse(result.canRetryPendingUpload)
                        XCTAssertEqual(h.store.state?.pending, pending)
                    } else if remoteKind == "missing" && emptyLocal {
                        XCTAssertEqual(result.phase, .paused)
                        XCTAssertTrue(result.canRetryPendingUpload)
                        XCTAssertEqual(h.store.state?.pending, pending)
                    } else if remoteKind == (emptyLocal ? "empty" : "current") {
                        XCTAssertEqual(result.phase, .synced)
                        XCTAssertNil(h.store.state?.pending)
                    } else {
                        XCTAssertEqual(result.phase, .conflicts)
                        XCTAssertEqual(result.conflicts.map(\.credentialID), ["fixture"])
                    }
                }
            }
        }
    }

    func testMissingInitialHeadRetryRequiresDurableStateAndUnchangedAccountAndRevision() async throws {
        for failure in ["transition-save", "finish-save", "account", "revision"] {
            let h = try SyncHarness()
            h.cloud.failUpload = .unavailable
            await h.engine.enable()
            let original = try XCTUnwrap(h.store.state?.pending)
            try h.local.change(CloudVaultSnapshot(credentials: [:]))
            h.cloud.failUpload = nil
            switch failure {
            case "transition-save": h.store.failOnSave = h.store.saves + 1
            case "finish-save": h.store.failOnSave = h.store.saves + 2
            case "account": h.cloud.afterFetch = { h.cloud.invalidated = true }
            default: h.local.beforeApply = { try h.local.change(syncSnapshot("newer")) }
            }
            await h.engine.retryPendingUpload()
            let result = await h.engine.status
            XCTAssertEqual(result.phase, .paused)
            XCTAssertEqual(result.error, failure == "account" ? .accountChanged : failure == "revision" ? .localChanged : .stateUnavailable)
            XCTAssertEqual(h.store.state?.pending, original)
            XCTAssertNil(h.store.state?.baseData)
            XCTAssertNil(h.cloud.remote)
            XCTAssertEqual(h.cloud.uploads, 1)
            if failure == "revision" {
                XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("newer").encoded())
            } else { XCTAssertTrue(h.local.value.credentials.isEmpty) }
            if failure.hasSuffix("save") {
                let stagedID = h.store.state?.transition?.upload?.id
                h.store.failOnSave = nil
                await h.engine.retryPendingUpload()
                let recovered = await h.engine.status
                XCTAssertEqual(recovered.phase, .synced)
                XCTAssertNil(h.store.state?.pending)
                XCTAssertNil(h.store.state?.transition)
                XCTAssertEqual(h.cloud.uploads, 2)
                XCTAssertTrue(h.cloud.remote?.snapshot.credentials.isEmpty == true)
                if let stagedID { XCTAssertEqual(h.cloud.remote?.revisionID, stagedID) }
            }
        }
    }

    func testMissingInitialHeadAppearingDuringExplicitRetryStillUsesCAS() async throws {
        for emptyRemote in [false, true] {
            let h = try SyncHarness()
            h.cloud.failUpload = .unavailable
            await h.engine.enable()
            try h.local.change(CloudVaultSnapshot(credentials: [:]))
            h.cloud.failUpload = nil
            let appearing = try emptyRemote ? CloudVaultSnapshot(credentials: [:]) : syncSnapshot("remote")
            h.cloud.beforeUpload = { h.cloud.setRemote(appearing) }
            await h.engine.retryPendingUpload()
            let rejected = await h.engine.status
            XCTAssertEqual(rejected.error, .conflict)
            XCTAssertNotNil(h.store.state?.pending)
            XCTAssertTrue(try XCTUnwrap(h.store.state?.pending).snapshot().credentials.isEmpty)
            XCTAssertEqual(try h.cloud.remote?.snapshot.encoded(), try appearing.encoded())
            XCTAssertTrue(h.local.value.credentials.isEmpty)
            XCTAssertEqual(h.cloud.uploads, 2)
            await h.engine.syncNow()
            let checked = await h.engine.status
            XCTAssertEqual(h.cloud.uploads, 2)
            if emptyRemote {
                XCTAssertEqual(checked.phase, .synced)
                XCTAssertNil(h.store.state?.pending)
            } else {
                XCTAssertEqual(checked.phase, .conflicts)
                XCTAssertEqual(checked.conflicts.map(\.credentialID), ["fixture"])
                XCTAssertEqual(checked.conflicts.first?.localDeleted, true)
            }
        }
    }

    func testMissingKnownHeadWithEmptyLocalNeverOffersOrPerformsRetry() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        try h.local.change(syncSnapshot("pending"))
        h.cloud.failUpload = .unavailable
        await h.engine.syncNow()
        let original = try XCTUnwrap(h.store.state?.pending), base = h.store.state?.baseData
        XCTAssertNotNil(original.expectedRevisionID)
        try h.local.change(CloudVaultSnapshot(credentials: [:]))
        h.cloud.remote = nil; h.cloud.failUpload = nil
        await h.engine.syncNow()
        await h.engine.disable(); await h.engine.enable()
        await h.engine.retryPendingUpload()
        let result = await h.engine.status
        XCTAssertEqual(result.error, .unavailable)
        XCTAssertFalse(result.canRetryPendingUpload)
        XCTAssertNil(result.reviewID)
        XCTAssertEqual(h.store.state?.pending, original)
        XCTAssertEqual(h.store.state?.baseData, base)
        XCTAssertEqual(h.cloud.uploads, 2)
        XCTAssertTrue(h.local.value.credentials.isEmpty)
        XCTAssertNil(h.cloud.remote)
    }

    func testUnknownWriteDoesNotAutomaticallyReplayAndExplicitRetryChecksHead() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        let pendingID = try XCTUnwrap(h.store.state?.pending?.id)
        h.cloud.failUpload = nil
        await h.engine.syncNow()
        let waiting = await h.engine.status
        XCTAssertTrue(waiting.canRetryPendingUpload)
        XCTAssertEqual(h.cloud.uploads, 1)
        await h.engine.retryPendingUpload()
        XCTAssertEqual(h.cloud.uploads, 2)
        XCTAssertEqual(h.cloud.remote?.revisionID, pendingID)
        XCTAssertNil(h.store.state?.pending)
    }

    func testAccountInvalidationAfterFetchCannotApplyOrAdvanceBase() async throws {
        let h = try SyncHarness()
        h.cloud.afterFetch = { h.cloud.invalidated = true }
        await h.engine.enable()
        let status = await h.engine.status
        XCTAssertEqual(status.error, .accountChanged)
        XCTAssertEqual(h.local.applies, 0)
        XCTAssertEqual(h.cloud.uploads, 0)
        XCTAssertNil(h.store.state?.baseData)
        XCTAssertTrue(h.store.state?.accountChangePaused == true)
    }

    func testAccountChangePersistsPauseAndRefusesDifferentAccount() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        let base = h.store.state?.baseData
        await h.engine.accountChanged()
        let restarted = h.restart()
        await restarted.load(); await restarted.syncNow()
        XCTAssertEqual(h.cloud.uploads, 1)
        h.cloud.account = .init(container: "synthetic", environment: "Production", accountID: "different")
        await restarted.enable()
        let status = await restarted.status
        XCTAssertEqual(status.error, .accountChanged)
        XCTAssertEqual(h.store.state?.baseData, base)
        XCTAssertEqual(h.store.state?.binding?.accountID, "synthetic-account")
    }

    func testDisableDuringFetchBlocksLateResultAndRetainsSingleFlight() async throws {
        let h = try SyncHarness(), pause = SyncSuspension()
        h.cloud.fetchGate = pause
        let operation = Task { await h.engine.enable() }
        try await pause.waitUntilEntered()
        await h.engine.disable()
        await h.engine.enable()
        XCTAssertEqual(h.factory.calls, 1)
        await pause.release(); await operation.value
        let status = await h.engine.status
        XCTAssertEqual(status.phase, .off)
        XCTAssertFalse(status.enabled)
        XCTAssertFalse(status.busy)
        XCTAssertEqual(h.local.applies, 0)
        XCTAssertEqual(h.cloud.uploads, 0)
        XCTAssertNil(h.store.state?.baseData)
    }

    func testDisableAfterUploadKeepsPendingAndDoesNotAdvanceBaseOnLateReadback() async throws {
        let h = try SyncHarness(), pause = SyncSuspension()
        h.cloud.fetchGate = pause; h.cloud.pauseOnFetch = 2
        let operation = Task { await h.engine.enable() }
        try await pause.waitUntilEntered()
        XCTAssertEqual(h.cloud.uploads, 1)
        XCTAssertNotNil(h.cloud.remote)
        XCTAssertNotNil(h.store.state?.pending)
        await h.engine.disable()
        await pause.release(); await operation.value
        let status = await h.engine.status
        XCTAssertEqual(status.phase, .off)
        XCTAssertNil(h.store.state?.baseData)
        XCTAssertNotNil(h.store.state?.pending)
        h.cloud.fetchGate = nil
        await h.engine.enable()
        XCTAssertEqual(h.cloud.uploads, 1)
        XCTAssertNil(h.store.state?.pending)
    }

    func testNativeTimeoutOwnershipBlocksReplacementUntilActualCallback() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        h.cloud.beforeUpload = { h.cloud.hasOutstandingOperation = true }
        await h.engine.enable()
        let waiting = await h.engine.status
        XCTAssertTrue(waiting.busy)
        await h.engine.disable(); await h.engine.enable()
        XCTAssertEqual(h.factory.calls, 1, "Timeout is not native completion")
        h.cloud.hasOutstandingOperation = false
        h.cloud.beforeUpload = nil
        await h.engine.enable()
        XCTAssertEqual(h.factory.calls, 2)
        XCTAssertEqual(h.cloud.uploads, 1, "Resume only reads pending result")
    }

    func testDisablePersistenceFailureNeverClaimsOff() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        h.store.failSave = true
        await h.engine.disable()
        let failed = await h.engine.status
        XCTAssertEqual(failed.phase, .paused)
        XCTAssertEqual(failed.error, .stateUnavailable)
        XCTAssertTrue(failed.enabled)
        let uploads = h.cloud.uploads, saves = h.store.saves, applies = h.local.applies
        await h.engine.syncNow()
        XCTAssertEqual(h.cloud.uploads, uploads)
        XCTAssertEqual(h.store.saves, saves)
        XCTAssertEqual(h.local.applies, applies)
        let stillPaused = await h.engine.status
        XCTAssertEqual(stillPaused.phase, .paused)
    }

    func testConflictPreservesBothUntilExplicitChoiceAndRejectsStaleReview() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        try h.local.change(syncSnapshot("local"))
        h.cloud.setRemote(try syncSnapshot("remote"))
        let before = try h.local.value.encoded(), remote = try h.cloud.remote?.snapshot.encoded()
        await h.engine.syncNow()
        let review = await h.engine.status
        XCTAssertEqual(review.phase, .conflicts)
        XCTAssertEqual(review.conflicts.map(\.credentialID), ["fixture"])
        XCTAssertEqual(try h.local.value.encoded(), before)
        XCTAssertEqual(try h.cloud.remote?.snapshot.encoded(), remote)
        try h.local.change(syncSnapshot("newer"))
        await h.engine.resolve(reviewID: try XCTUnwrap(review.reviewID), choices: ["fixture": .remote])
        let stale = await h.engine.status
        XCTAssertEqual(stale.error, .localChanged)
        XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("newer").encoded())
        await h.engine.syncNow()
        let fresh = await h.engine.status
        await h.engine.resolve(reviewID: try XCTUnwrap(fresh.reviewID), choices: ["fixture": .local])
        let resolved = await h.engine.status
        XCTAssertEqual(resolved.phase, .synced)
        XCTAssertEqual(try h.cloud.remote?.snapshot.encoded(), try syncSnapshot("newer").encoded())
    }

    func testRemoteChangedWhileReviewOpenRejectsOldChoice() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        try h.local.change(syncSnapshot("local")); h.cloud.setRemote(try syncSnapshot("remote"))
        await h.engine.syncNow()
        let review = await h.engine.status
        h.cloud.setRemote(try syncSnapshot("remote-new"))
        await h.engine.resolve(reviewID: try XCTUnwrap(review.reviewID), choices: ["fixture": .local])
        let result = await h.engine.status
        XCTAssertEqual(result.error, .localChanged)
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testPendingAfterLocalOnlyDeletionRequiresExplicitReviewAndDoesNotResurrect() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        try h.local.change(CloudVaultSnapshot(credentials: [:]))
        h.cloud.setRemote(try syncSnapshot("one"))
        h.cloud.failUpload = nil
        await h.engine.syncNow()
        let review = await h.engine.status
        XCTAssertEqual(review.phase, .conflicts)
        XCTAssertTrue(try XCTUnwrap(review.conflicts.first).localDeleted)
        XCTAssertTrue(h.local.value.credentials.isEmpty)
        XCTAssertEqual(h.cloud.uploads, 1)
        await h.engine.resolve(reviewID: try XCTUnwrap(review.reviewID), choices: ["fixture": .local])
        XCTAssertTrue(h.cloud.remote?.snapshot.credentials.isEmpty == true)
        XCTAssertTrue(h.local.value.credentials.isEmpty)
        XCTAssertNil(h.store.state?.pending)
    }

    func testPendingExpectedHeadWithNewLocalEditCannotReplayOldCandidate() async throws {
        let h = try SyncHarness()
        h.cloud.failUpload = .unavailable
        await h.engine.enable()
        try h.local.change(syncSnapshot("newer"))
        h.cloud.failUpload = nil
        await h.engine.retryPendingUpload()
        let review = await h.engine.status
        XCTAssertEqual(review.phase, .conflicts)
        XCTAssertEqual(h.cloud.uploads, 1)
        XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("newer").encoded())
    }

    func testVanishedPreviouslyKnownHeadIsNotAnEmptyVault() async throws {
        let h = try SyncHarness()
        await h.engine.enable()
        let baseline = h.store.state?.baseData, local = try h.local.value.encoded()
        h.cloud.remote = nil
        await h.engine.syncNow()
        let status = await h.engine.status
        XCTAssertEqual(status.error, .unavailable)
        XCTAssertEqual(h.store.state?.baseData, baseline)
        XCTAssertEqual(try h.local.value.encoded(), local)
        XCTAssertEqual(h.cloud.uploads, 1)
    }

    func testTransitionRecoversAfterApplyBeforeStateAdvance() async throws {
        let h = try SyncHarness()
        h.cloud.setRemote(try syncSnapshot("remote", id: "remote"))
        h.store.failOnSave = 3 // enabled, transition, then completed local apply
        await h.engine.enable()
        XCTAssertNotNil(h.store.state?.transition)
        XCTAssertEqual(Set(h.local.value.credentials.keys), ["fixture", "remote"])
        XCTAssertEqual(h.cloud.uploads, 0)
        h.store.failOnSave = nil
        let restarted = h.restart()
        await restarted.load(); await restarted.syncNow()
        XCTAssertNil(h.store.state?.transition)
        XCTAssertNotNil(h.store.state?.pending)
        XCTAssertEqual(h.store.state?.baseData, try h.cloud.remote?.snapshot.encoded())
        await restarted.retryPendingUpload()
        let status = await restarted.status
        XCTAssertEqual(status.phase, .synced)
        XCTAssertEqual(Set(h.cloud.remote!.snapshot.credentials.keys), ["fixture", "remote"])
    }

    func testTransitionThirdLocalStateRemainsPreservedAndPaused() async throws {
        let h = try SyncHarness()
        h.local.failApply = true
        h.cloud.setRemote(try syncSnapshot("remote", id: "remote"))
        await h.engine.enable()
        XCTAssertNotNil(h.store.state?.transition)
        h.local.failApply = false
        try h.local.change(syncSnapshot("third"))
        let restarted = h.restart()
        await restarted.load(); await restarted.syncNow()
        let status = await restarted.status
        XCTAssertEqual(status.error, .stateUnavailable)
        XCTAssertEqual(try h.local.value.encoded(), try syncSnapshot("third").encoded())
        XCTAssertNotNil(h.store.state?.transition)
        XCTAssertEqual(h.cloud.uploads, 0)
    }

    func testStateRejectsUnknownSchemaAndResolvesOneUncertainWriteByReadback() throws {
        let io = FakeKeychainIO(), marker = TestJournalMarker()
        let store = CloudSyncStateStore(io: io, marker: marker, namespace: "fixture")
        io.afterWrite = { throw CloudSyncError.unavailable }
        try store.save(.init())
        XCTAssertEqual(io.writes, 1)
        let original = try XCTUnwrap(io.blob)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["extra"] = "must-not-disappear"
        io.blob = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(.init()))
        XCTAssertEqual(io.writes, 1)
    }

}

private final class SyncHarness {
    let local: SyncLocal
    let store = SyncMemoryState()
    let cloud = SyncCloud()
    let factory: SyncFactory
    let engine: CloudSyncCoordinator
    func restart() -> CloudSyncCoordinator {
        let factory = factory
        return CloudSyncCoordinator(local: local, stateStore: store, makeTransport: { factory.make() })
    }
    init() throws {
        local = SyncLocal(try syncSnapshot("one"))
        factory = SyncFactory(cloud)
        let factory = factory
        engine = CloudSyncCoordinator(local: local, stateStore: store, makeTransport: { factory.make() })
    }
}
private func syncSnapshot(_ value: String, id: String = "fixture", note: String = "") throws -> CloudVaultSnapshot {
    try CloudVaultSnapshot(credentials: [id: .init(metadata: .init(label: "Synthetic", notes: note, links: [],
        fields: ["token": .init(secret: true)], security: .strict, created: "2026-11-02", updated: "2026-11-02"),
        secrets: ["token": "synthetic-" + value])])
}
private final class SyncFactory: @unchecked Sendable {
    var calls = 0
    let cloud: SyncCloud
    init(_ cloud: SyncCloud) { self.cloud = cloud }
    func make() -> any CloudSyncTransport { calls += 1; return cloud }
}
private final class SyncMemoryState: CloudSyncStateStoring, @unchecked Sendable {
    var state: CloudSyncStoredState?
    var failSave = false
    var failOnSave: Int?
    var saves = 0
    func load() throws -> CloudSyncStoredState? { state }
    func save(_ state: CloudSyncStoredState) throws {
        saves += 1
        if failSave || failOnSave == saves { throw CloudSyncError.stateUnavailable }
        try state.validate(); self.state = state
    }
}
private final class SyncLocal: CloudSyncLocalStore, @unchecked Sendable {
    let gate = VaultAccessGate()
    var value: CloudVaultSnapshot
    var reads = 0, applies = 0
    var failApply = false
    var beforeApply: (() throws -> Void)?
    init(_ value: CloudVaultSnapshot) { self.value = value }
    func capture() throws -> CloudSyncLocalCapture {
        try gate.withAccess {
            reads += 1
            return try .init(snapshot: value, revision: gate.revision(for: MetaFile(credentials: value.credentials.mapValues(\.metadata))))
        }
    }
    func apply(_ desired: CloudVaultSnapshot, expectedRevision: VaultRevision) throws -> [String] {
        try beforeApply?()
        return try gate.withAccess {
            try gate.validateRevision(expectedRevision, metadata: MetaFile(credentials: value.credentials.mapValues(\.metadata)), required: true)
            if failApply { throw CloudSyncError.unavailable }
            return try gate.withCommit { applies += 1; value = desired; return Array(desired.credentials.keys) }
        }
    }
    func change(_ value: CloudVaultSnapshot) throws { try gate.withCommit { self.value = value } }
}
private final class SyncCloud: CloudSyncTransport, @unchecked Sendable {
    var hasOutstandingOperation = false
    let lock = NSRecursiveLock()
    var account = CloudSyncBinding(container: "synthetic", environment: "Production", accountID: "synthetic-account")
    var remote: CloudSyncRemote?
    var uploads = 0, fetches = 0, cancels = 0
    var failUpload: CloudSyncError?
    var commitThenFail = false
    var invalidated = false
    var beforeUpload: (() -> Void)?
    var afterUpload: (() throws -> Void)?
    var afterFetch: (() -> Void)?
    var fetchGate: SyncSuspension?
    var pauseOnFetch: Int?
    func setRemote(_ snapshot: CloudVaultSnapshot) {
        let id = UUID()
        remote = .init(revisionID: id, snapshot: snapshot, changeToken: Data(id.uuidString.utf8))
    }
    func binding() async throws -> CloudSyncBinding { account }
    func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote? {
        fetches += 1; let result = remote
        if let fetchGate, pauseOnFetch == nil || pauseOnFetch == fetches { await fetchGate.pause() }
        afterFetch?(); return result
    }
    func upload(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding) async throws {
        uploads += 1; beforeUpload?()
        if let failUpload, !commitThenFail { throw failUpload }
        guard remote?.revisionID == pending.expectedRevisionID, remote?.changeToken == pending.expectedChangeToken else { throw CloudSyncError.conflict }
        remote = try .init(revisionID: pending.id, snapshot: pending.snapshot(), changeToken: Data(pending.id.uuidString.utf8))
        try afterUpload?()
        if let failUpload { throw failUpload }
    }
    func cancel() { cancels += 1 }
    func withCurrentBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T {
        try lock.withLock {
            guard !invalidated, binding == account else { throw CloudSyncError.accountChanged }
            return try effect()
        }
    }
}

private actor SyncSuspension {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async throws {
        for _ in 0..<200 {
            if entered { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw CloudSyncError.unavailable
    }
    func release() { continuation?.resume(); continuation = nil }
}
