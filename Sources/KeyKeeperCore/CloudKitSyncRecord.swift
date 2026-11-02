import Foundation
import CloudKit
import CryptoKit

/// Only authenticated ciphertext and random identifiers enter a cloud record. System fields
/// preserve Apple's change tag for ifServerRecordUnchanged; see CKRecord.encodeSystemFields.
enum CloudKitSyncRecord {
    static let recordType = "KeyKeeperVault"
    static let zoneName = "KeyKeeperVault-v1"
    struct Payload {
        let vaultID: UUID
        let keyID: UUID
        let revisionID: UUID
        let ciphertext: Data
        func context(_ binding: CloudSyncBinding) -> CloudVaultEnvelopeContext {
            .init(container: binding.container, environment: binding.environment, account: binding.accountID,
                  vaultID: vaultID, keyID: keyID, revisionID: revisionID)
        }
    }
    struct ChangeToken: Codable {
        let version: Int
        let binding: CloudSyncBinding
        let vaultID: UUID
        let keyID: UUID
        let revisionID: UUID
        let systemFields: Data
    }
    static func recordID(_ binding: CloudSyncBinding) -> CKRecord.ID {
        .init(recordName: "head", zoneID: .init(zoneName: zoneName, ownerName: binding.accountID))
    }
    static func payload(_ record: CKRecord, binding: CloudSyncBinding) throws -> Payload {
        guard record.recordType == recordType, record.recordID == recordID(binding),
              Set(record.allKeys()) == ["vaultID", "keyID", "revisionID", "ciphertext"],
              let v = record["vaultID"] as? String, let vault = UUID(uuidString: v),
              let k = record["keyID"] as? String, let key = UUID(uuidString: k),
              let r = record["revisionID"] as? String, let revision = UUID(uuidString: r),
              let ciphertext = record["ciphertext"] as? Data,
              ciphertext.count <= CloudVaultEnvelope.maximumBytes else { throw CloudSyncError.stateUnavailable }
        return Payload(vaultID: vault, keyID: key, revisionID: revision, ciphertext: ciphertext)
    }
    static func changeToken(_ record: CKRecord, payload: Payload, binding: CloudSyncBinding) throws -> Data {
        guard record.recordChangeTag?.isEmpty == false else { throw CloudSyncError.stateUnavailable }
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return try CloudVaultSnapshot.encode(ChangeToken(version: 1, binding: binding, vaultID: payload.vaultID,
            keyID: payload.keyID, revisionID: payload.revisionID, systemFields: coder.encodedData))
    }
    static func restore(_ data: Data, binding: CloudSyncBinding, revision: UUID) throws -> (CKRecord, ChangeToken) {
        guard data.count <= 1024 * 1024 else { throw CloudSyncError.stateUnavailable }
        let token = try JSONDecoder().decode(ChangeToken.self, from: data)
        guard token.version == 1, token.binding == binding, token.revisionID == revision,
              try CloudVaultSnapshot.encode(token) == data else { throw CloudSyncError.accountChanged }
        let decoder = try NSKeyedUnarchiver(forReadingFrom: token.systemFields)
        decoder.requiresSecureCoding = true
        defer { decoder.finishDecoding() }
        guard let record = CKRecord(coder: decoder), record.recordType == recordType,
              record.recordID == recordID(binding), record.recordChangeTag?.isEmpty == false,
              record.allKeys().isEmpty else { throw CloudSyncError.stateUnavailable }
        return (record, token)
    }
    static func apply(_ payload: Payload, to record: CKRecord) {
        record["vaultID"] = payload.vaultID.uuidString as CKRecordValue
        record["keyID"] = payload.keyID.uuidString as CKRecordValue
        record["revisionID"] = payload.revisionID.uuidString as CKRecordValue
        record["ciphertext"] = payload.ciphertext as CKRecordValue
    }
}
