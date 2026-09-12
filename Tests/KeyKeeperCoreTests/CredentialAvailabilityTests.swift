import XCTest
import Security
@testable import KeyKeeperCore

final class CredentialAvailabilityTests: XCTestCase {
    private final class InspectionIO: KeychainBlobIO, @unchecked Sendable {
        var data: Data?
        var error: Error?
        var ordinaryReads = 0
        var writes = 0
        func readBlob() throws -> Data? { ordinaryReads += 1; return data }
        func readBlobWithoutInteraction() throws -> Data? {
            if let error { throw error }
            return data
        }
        func writeBlob(_ data: Data, replacingExisting: Bool) throws { writes += 1 }
    }

    func testInventoryIsNonInteractiveReadOnlyAndDistinguishesErrors() throws {
        let io = InspectionIO()
        let store = KeychainBlobStore(io: io)
        XCTAssertEqual(try store.inspectValueInventory(), [:])
        io.data = Data(#"{"version":1,"credentials":{"fixture":{"field":"synthetic"}}}"#.utf8)
        XCTAssertEqual(try store.inspectValueInventory(), ["fixture": ["field"]])
        io.error = KeychainError.retrieveFailed(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.inspectValueInventory())
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertEqual(io.writes, 0)
    }

    func testCorruptAndUnknownVersionNeverBecomeMissing() {
        let io = InspectionIO()
        let store = KeychainBlobStore(io: io)
        for text in ["broken", #"{"version":99,"credentials":{}}"#] {
            io.data = Data(text.utf8)
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
