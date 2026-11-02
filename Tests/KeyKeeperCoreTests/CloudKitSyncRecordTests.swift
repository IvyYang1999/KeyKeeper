import XCTest
import CloudKit
import CryptoKit
import Security
@testable import KeyKeeperCore

final class CloudKitSyncRecordTests: XCTestCase {
    private let binding = CloudSyncBinding(container: CloudSyncNativeIdentity.container,
                                           environment: "Production", accountID: "synthetic-account")
    func testOnlyEncryptedBoundSnapshotEntersRecord() throws {
        let snapshot = try CloudVaultSnapshot(credentials: ["fixture": .init(metadata: .init(label: "Synthetic",
            notes: "private synthetic note", links: [], fields: ["key": .init(secret: true)],
            security: .strict, created: "now", updated: "now"), secrets: ["key": "synthetic-secret"])])
        let key = SymmetricKey(size: .bits256), vault = UUID(), keyID = UUID(), revision = UUID()
        let context = CloudVaultEnvelopeContext(container: binding.container, environment: binding.environment,
            account: binding.accountID, vaultID: vault, keyID: keyID, revisionID: revision)
        let payload = try CloudKitSyncRecord.Payload(vaultID: vault, keyID: keyID, revisionID: revision,
            ciphertext: CloudVaultEnvelope.seal(snapshot, key: key, context: context))
        let record = CKRecord(recordType: CloudKitSyncRecord.recordType, recordID: CloudKitSyncRecord.recordID(binding))
        CloudKitSyncRecord.apply(payload, to: record)
        let decoded = try CloudKitSyncRecord.payload(record, binding: binding)
        XCTAssertEqual(try CloudVaultEnvelope.open(decoded.ciphertext, key: key, expectedContext: decoded.context(binding)).encoded(), try snapshot.encoded())
        XCTAssertFalse(String(decoding: decoded.ciphertext, as: UTF8.self).contains("synthetic-secret"))
        XCTAssertFalse(String(decoding: decoded.ciphertext, as: UTF8.self).contains("private synthetic note"))
        record["grants"] = "must-not-transfer" as CKRecordValue
        XCTAssertThrowsError(try CloudKitSyncRecord.payload(record, binding: binding))
    }
    func testWrongAccountZoneAndUncommittedChangeTokenRefuse() throws {
        let record = CKRecord(recordType: CloudKitSyncRecord.recordType, recordID: CloudKitSyncRecord.recordID(binding))
        let payload = CloudKitSyncRecord.Payload(vaultID: UUID(), keyID: UUID(), revisionID: UUID(), ciphertext: Data())
        CloudKitSyncRecord.apply(payload, to: record)
        var other = binding
        other = .init(container: binding.container, environment: binding.environment, accountID: "other-account")
        XCTAssertThrowsError(try CloudKitSyncRecord.payload(record, binding: other))
        XCTAssertThrowsError(try CloudKitSyncRecord.changeToken(record, payload: payload, binding: binding))
        XCTAssertThrowsError(try CloudKitSyncRecord.restore(Data("{}".utf8), binding: binding, revision: UUID()))
    }
    func testRootQueryOnlySyncsRootAndSeparatesAccountsAndEnvironments() {
        let vault = UUID(), key = UUID()
        let query = CloudSyncRootKey.query(binding: binding, vault: vault, key: key)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, StorageIdentity.accessGroup)
        XCTAssertNil(query[kSecValueData as String])
        for other in [CloudSyncBinding(container: binding.container, environment: "Development", accountID: binding.accountID),
                      .init(container: binding.container, environment: "Production", accountID: "other")] {
            XCTAssertNotEqual(query[kSecAttrService as String] as? String,
                CloudSyncRootKey.query(binding: other, vault: vault, key: key)[kSecAttrService as String] as? String)
        }
    }
}
