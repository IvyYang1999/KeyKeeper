import XCTest
@testable import KeyKeeperCore

final class KeychainServiceTests: XCTestCase {
    private let service = KeychainService()
    private let testCredId = "test-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KEYKEEPER_TEST_REAL_KEYCHAIN"] == "1",
            "Skipped by default because these legacy integration tests use the login Keychain."
        )
    }

    override func tearDown() {
        guard ProcessInfo.processInfo.environment["KEYKEEPER_TEST_REAL_KEYCHAIN"] == "1" else {
            return
        }
        try? service.delete(credentialId: testCredId, fieldName: "api_key")
    }

    func testSaveAndRetrieve() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "opaque-test-value", security: .standard)
        let value = try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        XCTAssertEqual(value, "opaque-test-value")
    }

    func testRetrieveNonExistent() {
        XCTAssertThrowsError(
            try service.retrieve(credentialId: "nonexistent", fieldName: "key")
        )
    }

    func testUpdate() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "old-value", security: .standard)
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "new-value", security: .standard)
        let value = try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        XCTAssertEqual(value, "new-value")
    }

    func testDelete() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "to-delete", security: .standard)
        try service.delete(credentialId: testCredId, fieldName: "api_key")
        XCTAssertThrowsError(
            try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        )
    }
}
