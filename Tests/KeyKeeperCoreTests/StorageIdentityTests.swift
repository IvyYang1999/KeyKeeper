import XCTest
import Security
@testable import KeyKeeperCore

final class StorageIdentityTests: XCTestCase {
    func testNewIdentityUsesIndependentLocalNamespace() throws {
        XCTAssertEqual(StorageIdentity.resolve(bundleIdentifier: "dev.keykeeper.app", environment: [:]), .current)
        XCTAssertEqual(StorageIdentity.resolve(bundleIdentifier: "com.keykeeper.app", environment: [:]), .legacy)
        XCTAssertNotEqual(StorageIdentity.current.credentialsService, StorageIdentity.legacy.credentialsService)
        XCTAssertNotEqual(StorageIdentity.current.directoryName, StorageIdentity.legacy.directoryName)
        XCTAssertTrue(StorageIdentity.current.requiresBoundRequests)
        XCTAssertFalse(StorageIdentity.legacy.requiresBoundRequests)
    }

    func testCurrentScopeCannotQueryLoginOrSynchronizableValues() {
        let query = SecItemBlobIO.readQuery(service: "fixture", allowInteraction: false, identity: .current)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, StorageIdentity.accessGroup)
        let legacy = SecItemBlobIO.readQuery(service: "fixture", allowInteraction: false, identity: .legacy)
        XCTAssertNil(legacy[kSecUseDataProtectionKeychain as String])
        XCTAssertNil(legacy[kSecAttrAccessGroup as String])
    }

    func testIsolatedTripleKeepsExistingTestNamespace() {
        let env = ["KEYKEEPER_DATA_DIR": "/tmp/keykeeper-data", "KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.identity",
                   "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-identity.sock"]
        XCTAssertEqual(StorageIdentity.resolve(bundleIdentifier: "dev.keykeeper.app", environment: env), .legacy)
        XCTAssertEqual(try SecItemBlobIO.serviceName(environment: env), "com.keykeeper.test.identity")
    }
    func testEveryCurrentWriteKeepsDPGroupAndNeverSynchronizesPlaintextItems() throws {
        var updates: [[String: Any]] = [], additions: [[String: Any]] = []
        let io = SecItemBlobIO(service: "dev.keykeeper.fixture", updateItem: { query, _ in
            updates.append(query as! [String: Any]); return errSecSuccess
        }, addItem: { query in
            additions.append(query as! [String: Any]); return errSecSuccess
        }, identity: .current)
        try io.writeBlob(Data("synthetic".utf8), replacingExisting: false)
        try io.writeBlob(Data("synthetic-edit".utf8), replacingExisting: true)
        XCTAssertEqual(updates.count, 1); XCTAssertEqual(additions.count, 1)
        for query in updates + additions {
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, StorageIdentity.accessGroup)
        }
        XCTAssertEqual(additions[0][kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}
