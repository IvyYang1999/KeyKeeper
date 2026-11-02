#if KEYKEEPER_SYNC_ACCEPTANCE
import XCTest
import CloudKit
import Security
@testable import KeyKeeperCore

final class CloudSyncAcceptanceIsolationTests: XCTestCase {
    let binding = CloudSyncBinding(container: CloudSyncNativeIdentity.container,
        environment: "Production", accountID: "synthetic-account")

    func testScopeSeparatesProductionAndEachAcceptanceRun() throws {
        let first = CloudSyncScope.acceptance(UUID()), second = CloudSyncScope.acceptance(UUID())
        let scopes: [CloudSyncScope] = [.production, first, second]
        let ids = scopes.map { CloudKitSyncRecord.recordID(binding, scope: $0) }
        XCTAssertEqual(Set(ids.map(\.zoneID.zoneName)).count, 3)
        XCTAssertEqual(ids[0].zoneID.zoneName, "KeyKeeperVault-v1")
        let vault = UUID(), key = UUID()
        let queries = scopes.map { CloudSyncRootKey.query(binding: binding, vault: vault, key: key, scope: $0) }
        XCTAssertEqual(Set(queries.compactMap { $0[kSecAttrService as String] as? String }).count, 3)
        for query in queries {
            XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true)
            XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, StorageIdentity.accessGroup)
        }
    }

    func testAcceptanceRecordCannotBeReadInProductionOrAnotherRun() throws {
        let scope = CloudSyncScope.acceptance(UUID())
        let record = CKRecord(recordType: CloudKitSyncRecord.recordType,
            recordID: CloudKitSyncRecord.recordID(binding, scope: scope))
        let payload = CloudKitSyncRecord.Payload(vaultID: UUID(), keyID: UUID(), revisionID: UUID(), ciphertext: Data())
        CloudKitSyncRecord.apply(payload, to: record)
        XCTAssertEqual(try CloudKitSyncRecord.payload(record, binding: binding, scope: scope).revisionID, payload.revisionID)
        XCTAssertThrowsError(try CloudKitSyncRecord.payload(record, binding: binding, scope: .production))
        XCTAssertThrowsError(try CloudKitSyncRecord.payload(record, binding: binding, scope: .acceptance(UUID())))
    }
}
#endif
