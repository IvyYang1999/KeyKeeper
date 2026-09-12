import XCTest
import Foundation
import KeyKeeperCore
@testable import KeyKeeperCLI

final class ValueAvailabilityQueryTests: XCTestCase {
    func testOldGroupAliasUsesCurrentInventory() throws {
        let record = Credential(label: "Synthetic", notes: "", links: [],
            fields: ["example": .init(secret: true)], security: .standard,
            created: "", updated: "", aliases: ["old-name"])
        let data = try MetaCommand.metadataJSON(credentialId: "old-name",
            meta: .init(credentials: ["current-name": record]),
            inventory: ["current-name": ["example"]])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let state = try XCTUnwrap(object["valueStatus"] as? [String: Any])
        XCTAssertEqual(state["state"] as? String, "present")
    }
    func testMetadataReportsMissingAndOldOrUnavailableAppDoesNotClaimLoss() throws {
        let record = Credential(label: "Fixture", notes: "", links: [],
            fields: ["field": .init(secret: true)], security: .standard,
            created: "2026-01-01", updated: "2026-01-01")
        let missing = ValueAvailabilityQuery.result(id: "fixture", record: record, inventory: [:])
        XCTAssertEqual(missing.state, .missing)
        XCTAssertEqual(ValueAvailabilityQuery.result(id: "fixture", record: record, inventory: nil).state, .unavailable)
        let data = try ValueAvailabilityQuery.metadataJSON(record, availability: missing)
        let decoded = try JSONDecoder().decode(Credential.self, from: data)
        XCTAssertEqual(decoded.label, record.label)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((object["valueStatus"] as? [String: Any])?["state"] as? String, "missing")
    }

    func testOldWireMessagesStillDecodeAndInventoryContainsNamesOnly() throws {
        let old = Data(#"{"success":true,"state":"unlockedManual"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SessionControlResponse.self, from: old).valueInventory)
        let request = Data(#"{"action":"status"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SessionControlRequest.self, from: request).inspectValues)
        var response = SessionControlResponse(success: true)
        response.valueInventory = ["fixture": ["field"]]
        let restored = try JSONDecoder().decode(SessionControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(restored.valueInventory, response.valueInventory)
    }
}
