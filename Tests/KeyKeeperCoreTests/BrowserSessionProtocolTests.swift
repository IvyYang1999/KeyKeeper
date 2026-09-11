import XCTest
@testable import KeyKeeperCore

final class BrowserSessionProtocolTests: XCTestCase {
    func testIPCEnvelopeRoundTripsWithoutChangingLegacyMessages() throws {
        let request = IPCRequest.browserSession(.init(action: .list))
        let bytes = try JSONEncoder().encode(request)
        guard case .browserSession(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: bytes) else { return XCTFail() }
        XCTAssertEqual(decoded.action, .list)
        let reply = IPCResponse.browserSession(.init(success: false, errorCode: .denied))
        let response = try JSONDecoder().decode(IPCResponse.self, from: JSONEncoder().encode(reply))
        guard case .browserSession(let result) = response else { return XCTFail() }
        XCTAssertEqual(result.errorCode, .denied)
    }
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
