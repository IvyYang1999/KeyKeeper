import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class IdentityStartupAdmissionTests: XCTestCase {
    private let empty = IdentityMigrationPreview(hasLegacyData: false, credentialCount: 0, missingValueCount: 0, browserSessionCount: 0)
    private let legacy = IdentityMigrationPreview(hasLegacyData: true, credentialCount: 91, missingValueCount: 48, browserSessionCount: 0)

    func testFreshLaunchWaitsForConfirmationAndOnlyThenStartsServicesOnce() async {
        var migrationStatus = IdentityMigrationStatus.required
        var reads = 0, previews = 0, migrated = 0, preferences = 0, starts = 0
        let admission = IdentityStartupAdmission(operations: .init(
            status: { reads += 1; return migrationStatus }, recover: { XCTFail() },
            applyPreferences: { preferences += 1 },
            preview: { previews += 1; return self.empty },
            migrate: { migrated += 1; migrationStatus = .ready }), onReady: { starts += 1 })
        XCTAssertEqual(reads, 0)
        await admission.start()?.value
        XCTAssertEqual(previews, 1)
        XCTAssertEqual(migrated, 0); XCTAssertEqual(starts, 0)
        XCTAssertEqual(admission.stage, .firstInstall)
        await admission.prepare()
        XCTAssertTrue(admission.admitted)
        XCTAssertEqual(migrated, 1); XCTAssertEqual(preferences, 1); XCTAssertEqual(starts, 1)
        await admission.start()?.value; await admission.prepare()
        XCTAssertEqual(starts, 1)
    }

    /// 【曾经的 bug】第二台 Mac 首装看到「移动旧数据」。没有旧数据就是首次准备，有才是复制，并带数量。
    func test曾经的Bug首装与旧数据分开显示() async {
        for (preview, expected) in [(empty, IdentityStartupAdmission.Stage.firstInstall), (legacy, .legacyFound(legacy))] {
            let admission = IdentityStartupAdmission(operations: .init(
                status: { .required }, recover: { XCTFail() }, applyPreferences: { XCTFail() },
                preview: { preview }, migrate: { XCTFail("Looking must not copy") }), onReady: { XCTFail() })
            await admission.start()?.value
            XCTAssertEqual(admission.stage, expected)
            XCTAssertFalse(admission.admitted)
        }
    }

    /// 旧来源读不到时必须停在失败，不能降级成「全新安装」然后建一个空库。
    func testUnreadableSourceStopsAndNeverOffersAnEmptyStore() async {
        var previewError: IdentityMigrationError? = .legacyRunning
        let admission = IdentityStartupAdmission(operations: .init(
            status: { .required }, recover: { XCTFail() }, applyPreferences: { XCTFail() },
            preview: { if let previewError { throw previewError }; return self.legacy },
            migrate: { XCTFail("A failed look must not lead to a copy") }), onReady: { XCTFail() })
        await admission.start()?.value
        guard case .failed(let failure) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(failure.kind, .sourceUnreadable)
        XCTAssertEqual(failure.detail, IdentityMigrationError.legacyRunning.errorDescription)
        await admission.prepare()
        XCTAssertFalse(admission.admitted, "No setup button while the source is unreadable")

        previewError = .unsignedMetadata
        admission.retry(); while case .checking = admission.stage { await Task.yield() }
        guard case .failed(let unsupported) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(unsupported.kind, .unsupported)

        previewError = nil
        admission.retry(); while case .checking = admission.stage { await Task.yield() }
        XCTAssertEqual(admission.stage, .legacyFound(legacy), "Trying again after quitting the old App reads again")
    }

    /// 确认复制时旧 App 又被打开：这是「读不到旧数据」，不是「本机没准备好」。
    func testSourceErrorDuringCopyIsReportedAsUnreadableSource() async {
        let admission = IdentityStartupAdmission(operations: .init(
            status: { .required }, recover: { XCTFail() }, applyPreferences: { XCTFail() },
            preview: { self.legacy }, migrate: { throw IdentityMigrationError.legacyRunning }), onReady: { XCTFail() })
        await admission.start()?.value
        await admission.prepare()
        guard case .failed(let failure) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(failure.kind, .sourceUnreadable)
        XCTAssertFalse(admission.admitted)
    }

    func testPendingRecoveryAndPreferencesMustFinishBeforeAnyServiceStarts() {
        var migrationStatus = IdentityMigrationStatus.pending
        var events: [String] = []
        let admission = IdentityStartupAdmission(operations: .init(
            status: { migrationStatus },
            recover: { events.append("recover"); migrationStatus = .ready },
            applyPreferences: { events.append("preferences") },
            preview: { XCTFail("An interrupted copy must not look at the source again"); return self.empty },
            migrate: { XCTFail("Must not read another source") }), onReady: { events.append("services") })
        XCTAssertNil(admission.start())
        XCTAssertEqual(events, ["recover", "preferences", "services"])
    }

    func testUnavailableMigrationNeverLooksLikeEmptyReadyStore() async {
        for failingPhase in [IdentityMigrationStatus.required, .pending, .ready] {
            let admission = IdentityStartupAdmission(operations: .init(
                status: { failingPhase }, recover: { throw IdentityMigrationError.unavailable },
                applyPreferences: { throw IdentityMigrationError.unavailable },
                preview: { self.empty },
                migrate: { throw IdentityMigrationError.unavailable }), onReady: { XCTFail("Not admitted") })
            await admission.start()?.value; await admission.prepare()
            XCTAssertFalse(admission.admitted)
            guard case .failed(let failure) = admission.stage else { return XCTFail("\(failingPhase): \(admission.stage)") }
            XCTAssertEqual(failure.kind, .storage)
        }
    }
}
