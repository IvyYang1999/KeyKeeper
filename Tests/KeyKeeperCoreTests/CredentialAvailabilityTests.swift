import XCTest
import Security
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class CredentialAvailabilityTests: XCTestCase {

    func testInventoryIsNonInteractiveReadOnlyAndDistinguishesErrors() throws {
        let io = FakeKeychainIO()
        let store = KeychainBlobStore(io: io)
        XCTAssertEqual(try store.inspectValueInventory(), [:])
        io.blob = Data(#"{"version":1,"credentials":{"fixture":{"field":"synthetic"}}}"#.utf8)
        XCTAssertEqual(try store.inspectValueInventory(), ["fixture": ["field"]])
        io.readError = KeychainError.retrieveFailed(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.inspectValueInventory())
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertEqual(io.writes, 0)
    }

    func testCorruptAndUnknownVersionNeverBecomeMissing() {
        let io = FakeKeychainIO()
        let store = KeychainBlobStore(io: io)
        for text in ["broken", #"{"version":99,"credentials":{}}"#] {
            io.blob = Data(text.utf8)
            XCTAssertThrowsError(try store.inspectValueInventory())
        }
        XCTAssertEqual(io.writes, 0)
    }

    func testInspectionQueryForbidsAuthenticationUI() {
        let query = SecItemBlobIO.readQuery(service: "com.keykeeper.test.fixture", allowInteraction: false)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertNil(SecItemBlobIO.readQuery(service: "com.keykeeper.test.fixture", allowInteraction: true)[kSecUseAuthenticationUI as String])
    }
    // 【曾经的 bug】仅有元数据不能显示为可用。
    func testMissingFieldsAndRecovery() {
        let record = Credential(label: "Fixture", notes: "", links: [],
            fields: ["field": .init(secret: true), "other": .init(secret: true)],
            security: .strict, created: "2026-01-01", updated: "2026-01-01")
        let result = CredentialValueAvailability.check(record, presentFields: ["field"])
        XCTAssertEqual(result.state, .missing)
        XCTAssertEqual(result.missingFields, ["other"])
        XCTAssertEqual(CredentialValueAvailability.check(record, presentFields: ["field", "other"]).state, .present)
    }
}
