import Foundation
import CloudKit
import CryptoKit

/// Created only after explicit enable (or a previously persisted opt-in). Never log a native
/// CloudKit error: it may carry record/account details. The coordinator sees fixed errors only.
public final class CloudKitSyncTransport: CloudSyncTransport, @unchecked Sendable {
    private let container: CKContainer
    private let identity: CloudSyncNativeIdentity
    private let scope: CloudSyncScope
    private let fence = CloudSyncNativeFence()
    private var observer: NSObjectProtocol?
    public convenience init(identity: CloudSyncNativeIdentity) {
        self.init(identity: identity, scope: .production)
    }
    #if KEYKEEPER_SYNC_ACCEPTANCE
    public convenience init(identity: CloudSyncNativeIdentity, acceptanceRunID: UUID) {
        self.init(identity: identity, scope: .acceptance(acceptanceRunID))
    }
    #endif
    private init(identity: CloudSyncNativeIdentity, scope: CloudSyncScope) {
        self.identity = identity; self.scope = scope
        container = CKContainer(identifier: CloudSyncNativeIdentity.container)
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.fence.invalidate()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    public func cancel() { fence.invalidate() }
    public var hasOutstandingOperation: Bool { fence.hasOutstandingOperation }
    public func withCurrentBinding<T>(_ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T {
        try fence.withBinding(binding, effect)
    }
    public func binding() async throws -> CloudSyncBinding {
        let permit = try fence.capture()
        let status: CKAccountStatus = try await fence.perform { done in
            container.accountStatus { value, error in
                done(error == nil ? .success(value) : .failure(CloudSyncError.unavailable))
            }
        }
        if let error = Self.accountStatusError(status) { throw error }
        let recordID: CKRecord.ID = try await fence.perform { done in
            container.fetchUserRecordID { value, error in
                done(value.map(Result.success) ?? .failure(Self.userRecordError(error)))
            }
        }
        let binding = CloudSyncBinding(container: CloudSyncNativeIdentity.container,
            environment: identity.environment, accountID: recordID.recordName)
        try binding.validate()
        try fence.confirm(binding, permit: permit)
        return binding
    }
    /// 【曾经的 bug】2026-11-08：iCloud 一时答不上来（刚唤醒、刚登录、断网），也被当成「账号已更改」，
    /// 而且这个暂停会存下来，重启 App 也不消。Only a missing or restricted account is an account
    /// problem; "can't tell right now" is the same as no network. Neither yields a binding, so
    /// nothing is read or written either way: this only decides which pause, and its wording.
    static func accountStatusError(_ status: CKAccountStatus) -> CloudSyncError? {
        switch status {
        case .available: return nil
        case .couldNotDetermine, .temporarilyUnavailable: return .unavailable
        case .noAccount, .restricted: return .accountChanged
        @unknown default: return .accountChanged
        }
    }

    /// Network-class failures while asking who the user is are not evidence of a different user.
    static func userRecordError(_ error: Error?) -> CloudSyncError {
        switch (error as? CKError)?.code {
        case .networkUnavailable?, .networkFailure?, .serviceUnavailable?, .requestRateLimited?,
             .zoneBusy?, .accountTemporarilyUnavailable?:
            return .unavailable
        default:
            return .accountChanged
        }
    }

    private func verify(_ expected: CloudSyncBinding) async throws {
        guard try await binding() == expected else { throw CloudSyncError.accountChanged }
    }
    public func fetch(binding: CloudSyncBinding) async throws -> CloudSyncRemote? {
        try await verify(binding)
        let op = CKFetchRecordsOperation(recordIDs: [CloudKitSyncRecord.recordID(binding, scope: scope)])
        let box = CloudNativeResult<CKRecord>()
        op.perRecordResultBlock = { _, result in box.set(result) }
        let record: CKRecord? = try await fence.perform(cancel: { op.cancel() }) { done in
            op.fetchRecordsResultBlock = { overall in
                switch box.finish(overall) {
                case .success(let record): done(.success(record))
                case .failure(let error):
                    if let code = (error as? CKError)?.code, [.unknownItem, .zoneNotFound].contains(code) {
                        done(.success(nil))
                    } else { done(.failure(CloudSyncError.unavailable)) }
                }
            }
            submit(op)
        }
        try await verify(binding)
        return try withCurrentBinding(binding) {
            guard let record else { return nil }
            let payload = try CloudKitSyncRecord.payload(record, binding: binding, scope: scope)
            guard let key = try CloudSyncRootKey.read(binding: binding, vault: payload.vaultID, key: payload.keyID, scope: scope) else {
                // The other Mac's immutable root may still be arriving via iCloud Keychain.
                throw CloudSyncError.unavailable
            }
            let snapshot = try CloudVaultEnvelope.open(payload.ciphertext, key: key, expectedContext: payload.context(binding))
            return try CloudSyncRemote(revisionID: payload.revisionID, snapshot: snapshot,
                changeToken: CloudKitSyncRecord.changeToken(record, payload: payload, binding: binding, scope: scope))
        }
    }
    public func upload(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding) async throws {
        try pending.validate()
        try await verify(binding)
        let record: CKRecord = try withCurrentBinding(binding) {
            let record: CKRecord, vault: UUID, keyID: UUID, key: SymmetricKey
            if let token = pending.expectedChangeToken, let revision = pending.expectedRevisionID {
                let restored = try CloudKitSyncRecord.restore(token, binding: binding, revision: revision, scope: scope)
                record = restored.0; vault = restored.1.vaultID; keyID = restored.1.keyID
                guard let existing = try CloudSyncRootKey.read(binding: binding, vault: vault, key: keyID, scope: scope) else {
                    throw CloudSyncError.unavailable
                }
                key = existing
            } else {
                // Stable publication ID makes an explicitly retried first upload reuse its root.
                vault = pending.id; keyID = pending.id
                record = CKRecord(recordType: CloudKitSyncRecord.recordType, recordID: CloudKitSyncRecord.recordID(binding, scope: scope))
                key = try CloudSyncRootKey.createOrRead(binding: binding, vault: vault, key: keyID, scope: scope)
            }
            let context = CloudVaultEnvelopeContext(container: binding.container, environment: binding.environment,
                account: binding.accountID, vaultID: vault, keyID: keyID, revisionID: pending.id)
            let payload = try CloudKitSyncRecord.Payload(vaultID: vault, keyID: keyID, revisionID: pending.id,
                ciphertext: CloudVaultEnvelope.seal(pending.snapshot(), key: key, context: context))
            CloudKitSyncRecord.apply(payload, to: record)
            return record
        }
        if pending.expectedRevisionID == nil { try await createZone(binding) }
        try await verify(binding)
        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        op.savePolicy = .ifServerRecordUnchanged; op.isAtomic = true
        let box = CloudNativeResult<CKRecord>()
        op.perRecordSaveBlock = { _, result in box.set(result) }
        let _: CKRecord = try await fence.perform(cancel: { op.cancel() }) { done in
            op.modifyRecordsResultBlock = { overall in
                switch box.finish(overall) {
                case .success(let value): done(.success(value))
                case .failure(let error):
                    done(.failure((error as? CKError)?.code == .serverRecordChanged
                                  ? CloudSyncError.conflict : CloudSyncError.pendingUpload))
                }
            }
            submit(op)
        }
        try await verify(binding)
    }
    private func createZone(_ binding: CloudSyncBinding) async throws {
        try await verify(binding)
        let zone = CKRecordZone(zoneID: CloudKitSyncRecord.recordID(binding, scope: scope).zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: [])
        let box = CloudNativeResult<CKRecordZone>()
        op.perRecordZoneSaveBlock = { _, result in box.set(result) }
        let _: CKRecordZone = try await fence.perform(cancel: { op.cancel() }) { done in
            op.modifyRecordZonesResultBlock = { overall in
                done(box.finish(overall).mapError { _ in CloudSyncError.unavailable })
            }
            submit(op)
        }
    }
    private func submit(_ op: CKDatabaseOperation) {
        op.configuration.timeoutIntervalForRequest = 15
        op.configuration.timeoutIntervalForResource = 30
        container.privateCloudDatabase.add(op)
    }
}

private final class CloudNativeResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func set(_ result: Result<T, Error>) { lock.withLock { self.result = result } }
    func finish(_ overall: Result<Void, Error>) -> Result<T, Error> {
        lock.withLock {
            switch (overall, result) {
            case (.success, .some(let result)): return result
            case (.failure, .some(.failure(let error))): return .failure(error)
            case (.failure(let error), _): return .failure(error)
            default: return .failure(CloudSyncError.unavailable)
            }
        }
    }
}
