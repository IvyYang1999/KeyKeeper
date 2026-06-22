import XCTest
import Security
@testable import KeyKeeperCore

final class KeychainServiceTests: XCTestCase {
    let service = KeychainService()
    let testCredId = "test-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try XCTSkipUnless(
            Self.defaultKeychainAcceptsGenericPasswordItems(),
            "Default macOS Keychain is unavailable in this test environment."
        )
    }

    override func tearDown() {
        try? service.delete(credentialId: testCredId, fieldName: "api_key")
    }

    private static func defaultKeychainAcceptsGenericPasswordItems() -> Bool {
        let service = "keykeeper.test-canary.\(UUID().uuidString)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
            kSecValueData as String: Data("canary".utf8),
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        return status == errSecSuccess
    }

    func testSaveAndRetrieve() throws {
        try service.save(credentialId: testCredId, fieldName: "api_key",
                         value: "sk-test-123", security: .standard)
        let value = try service.retrieve(credentialId: testCredId, fieldName: "api_key")
        XCTAssertEqual(value, "sk-test-123")
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
