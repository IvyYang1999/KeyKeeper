import XCTest
@testable import KeyKeeperCore

final class CloudSyncContractTests: XCTestCase {
    func testPendingRoundTripBindsCompleteSnapshotAndConditionalVersion() throws {
        let snapshot = try CloudVaultSnapshot(credentials: [:])
        let pending = CloudSyncPendingUpload(id: UUID(), snapshotData: try snapshot.encoded(),
            expectedRevisionID: UUID(), expectedChangeToken: Data("synthetic-token".utf8))
        let encoded = try CloudVaultSnapshot.encode(pending)
        let decoded = try JSONDecoder().decode(CloudSyncPendingUpload.self, from: encoded)
        try decoded.validate()
        XCTAssertEqual(try decoded.snapshot().encoded(), try snapshot.encoded())
        XCTAssertEqual(decoded, pending)
        XCTAssertFalse(String(describing: pending).contains("synthetic-token"))
    }

    func testPendingRejectsUnpairedVersionAndInvalidSnapshot() throws {
        let empty = try CloudVaultSnapshot(credentials: [:]).encoded()
        XCTAssertThrowsError(try CloudSyncPendingUpload(id: UUID(), snapshotData: empty,
            expectedRevisionID: UUID(), expectedChangeToken: nil).validate())
        XCTAssertThrowsError(try CloudSyncPendingUpload(id: UUID(), snapshotData: Data("broken".utf8),
            expectedRevisionID: nil, expectedChangeToken: nil).validate())
        XCTAssertThrowsError(try CloudSyncBinding(container: "", environment: "Production", accountID: "account").validate())
    }
}
