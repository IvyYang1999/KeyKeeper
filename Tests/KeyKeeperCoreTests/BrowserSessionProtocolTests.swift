import XCTest
@testable import KeyKeeperCore

final class BrowserSessionProtocolTests: XCTestCase {
    func testMetadataRequestsRejectHiddenSnapshotAndInvalidTargets() throws {
        XCTAssertNoThrow(try BrowserSessionRequest(action: .list).validate())
        XCTAssertThrowsError(try BrowserSessionRequest(action: .list, id: UUID().uuidString).validate())
        XCTAssertThrowsError(try BrowserSessionRequest(action: .save).validate())
        for action: BrowserSessionRequest.Action in [.open, .stop, .delete] {
            XCTAssertThrowsError(try BrowserSessionRequest(action: action, id: "invalid").validate())
            XCTAssertNoThrow(try BrowserSessionRequest(action: action, id: UUID().uuidString).validate())
        }
    }
}
