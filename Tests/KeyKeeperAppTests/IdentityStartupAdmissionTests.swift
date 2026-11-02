import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class IdentityStartupAdmissionTests: XCTestCase {
    func testFreshLaunchWaitsForConfirmationAndOnlyThenStartsServicesOnce() async {
        var migrationStatus = IdentityMigrationStatus.required
        var reads = 0, migrated = 0, preferences = 0, starts = 0
        let admission = IdentityStartupAdmission(operations: .init(
            status: { reads += 1; return migrationStatus }, recover: { XCTFail() },
            applyPreferences: { preferences += 1 },
            migrate: { migrated += 1; migrationStatus = .ready }), onReady: { starts += 1 })
        XCTAssertEqual(reads, 0)
        admission.start()
        XCTAssertEqual(migrated, 0); XCTAssertEqual(starts, 0)
        XCTAssertEqual(admission.state.phase, .migrationRequired)
        await admission.migrateConfirmed()
        XCTAssertTrue(admission.admitted)
        XCTAssertEqual(migrated, 1); XCTAssertEqual(preferences, 1); XCTAssertEqual(starts, 1)
        admission.start(); await admission.migrateConfirmed()
        XCTAssertEqual(starts, 1)
    }

    func testPendingRecoveryAndPreferencesMustFinishBeforeAnyServiceStarts() {
        var migrationStatus = IdentityMigrationStatus.pending
        var events: [String] = []
        let admission = IdentityStartupAdmission(operations: .init(
            status: { migrationStatus },
            recover: { events.append("recover"); migrationStatus = .ready },
            applyPreferences: { events.append("preferences") },
            migrate: { XCTFail("Must not read another source") }), onReady: { events.append("services") })
        admission.start()
        XCTAssertEqual(events, ["recover", "preferences", "services"])
    }

    func testUnavailableMigrationNeverLooksLikeEmptyReadyStore() async {
        for failingPhase in [IdentityMigrationStatus.required, .pending, .ready] {
            let admission = IdentityStartupAdmission(operations: .init(
                status: { failingPhase }, recover: { throw IdentityMigrationError.unavailable },
                applyPreferences: { throw IdentityMigrationError.unavailable },
                migrate: { throw IdentityMigrationError.unavailable }), onReady: { XCTFail("Not admitted") })
            admission.start(); await admission.migrateConfirmed()
            XCTAssertFalse(admission.admitted)
            XCTAssertEqual(admission.state.phase, .migrationRequired)
            XCTAssertEqual(admission.state.issue, .storageUnavailable)
        }
    }
}
