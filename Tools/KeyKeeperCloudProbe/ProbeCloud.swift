import Foundation
import CloudKit
import Security

struct ProbeIdentity {
    let environment: String

    init() throws {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              dictionary[kSecCodeInfoIdentifier as String] as? String == "dev.keykeeper.app",
              dictionary[kSecCodeInfoTeamIdentifier as String] as? String == "ZPTA4LP594",
              let entitlements = dictionary[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              entitlements["com.apple.application-identifier"] as? String == ProbeOptions.applicationID,
              entitlements["com.apple.developer.team-identifier"] as? String == "ZPTA4LP594",
              (entitlements["keychain-access-groups"] as? [String])?.contains(ProbeOptions.applicationID) == true,
              entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] == [ProbeOptions.container],
              entitlements["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"],
              let environment = entitlements["com.apple.developer.icloud-container-environment"] as? String,
              ["Development", "Production"].contains(environment),
              Bundle.main.bundleIdentifier == "dev.keykeeper.app",
              FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path)
        else { throw ProbeFailure.identity }
        self.environment = environment
    }
}

final class ProbeCloud: @unchecked Sendable {
    let container = CKContainer(identifier: ProbeOptions.container)
    let environment: String
    let accountFence = ProbeAccountFence()
    private var observer: NSObjectProtocol?
    private let watchdog = DispatchSource.makeTimerSource(queue: .global())

    init(identity: ProbeIdentity) {
        environment = identity.environment
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.accountFence.invalidate()
        }
        watchdog.schedule(deadline: .now() + 45)
        watchdog.setEventHandler { [weak self] in
            // Exiting owns all late callbacks; uncertain writes remain in the encrypted journal.
            self?.accountFence.cancelCurrent()
            print("FAIL deadline_exceeded_read_back_before_retry")
            exit(70)
        }
        watchdog.resume()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        watchdog.cancel()
    }

    func account() async throws -> String {
        let permit = try accountFence.capture()
        guard try await container.accountStatus() == .available else { throw ProbeFailure.account }
        let name = try await container.userRecordID().recordName
        return try accountFence.withValid(permit) { name }
    }

    @discardableResult
    func verify(account expected: String) async throws -> ProbeAccountFence.Permit {
        let permit = try accountFence.capture()
        guard try await account() == expected else { throw ProbeFailure.account }
        return try accountFence.withValid(permit) { permit }
    }

    private func submit(_ operation: CKDatabaseOperation, permit: ProbeAccountFence.Permit, id: UUID) throws {
        operation.configuration.timeoutIntervalForRequest = 15
        operation.configuration.timeoutIntervalForResource = 30
        try accountFence.beginOperation(permit, id: id, cancel: { operation.cancel() }) {
            container.privateCloudDatabase.add(operation)
        }
    }

    func withVerifiedAccount<T>(_ permit: ProbeAccountFence.Permit, _ effect: () throws -> T) throws -> T {
        try accountFence.withValid(permit, effect)
    }

    func zoneID(runID: UUID, account: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: "KeyKeeperSynthetic-" + runID.uuidString, ownerName: account)
    }

    func fetch(runID: UUID, account: String) async throws -> CKRecord? {
        let permit = try await verify(account: account)
        let operationID = UUID()
        let id = CKRecord.ID(recordName: "head", zoneID: zoneID(runID: runID, account: account))
        let op = CKFetchRecordsOperation(recordIDs: [id])
        let box = ProbeResultBox<CKRecord>()
        op.perRecordResultBlock = { _, result in box.set(result) }
        let record: CKRecord? = try await withCheckedThrowingContinuation { continuation in
            op.fetchRecordsResultBlock = { [weak self] operationResult in
                guard self?.accountFence.finishOperation(permit, id: operationID) == true else {
                    continuation.resume(throwing: ProbeFailure.account); return
                }
                let result = box.finish(operationResult)
                switch result {
                case .success(let record): continuation.resume(returning: record)
                case .failure(let error):
                    if let code = (error as? CKError)?.code, [.unknownItem, .zoneNotFound].contains(code) {
                        continuation.resume(returning: nil)
                    } else { continuation.resume(throwing: error) }
                }
            }
            do { try submit(op, permit: permit, id: operationID) } catch { continuation.resume(throwing: error) }
        }
        try await verify(account: account)
        return record
    }

    func createZone(runID: UUID, account: String) async throws {
        let permit = try await verify(account: account)
        let operationID = UUID()
        let zone = CKRecordZone(zoneID: zoneID(runID: runID, account: account))
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: [])
        let box = ProbeResultBox<CKRecordZone>()
        op.perRecordZoneSaveBlock = { _, result in box.set(result) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.modifyRecordZonesResultBlock = { [weak self] operationResult in
                guard self?.accountFence.finishOperation(permit, id: operationID) == true else {
                    continuation.resume(throwing: ProbeFailure.account); return
                }
                switch box.finish(operationResult) {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            do { try submit(op, permit: permit, id: operationID) } catch { continuation.resume(throwing: error) }
        }
        try await verify(account: account)
    }

    func save(_ record: CKRecord, account: String) async throws {
        let permit = try await verify(account: account)
        let operationID = UUID()
        let op = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: [])
        op.savePolicy = .ifServerRecordUnchanged
        op.isAtomic = true
        let box = ProbeResultBox<CKRecord>()
        op.perRecordSaveBlock = { _, result in box.set(result) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            op.modifyRecordsResultBlock = { [weak self] operationResult in
                guard self?.accountFence.finishOperation(permit, id: operationID) == true else {
                    continuation.resume(throwing: ProbeFailure.account); return
                }
                switch box.finish(operationResult) {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            do { try submit(op, permit: permit, id: operationID) } catch { continuation.resume(throwing: error) }
        }
        try await verify(account: account)
    }
}

private final class ProbeResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    func set(_ value: Result<T, Error>) { lock.withLock { result = value } }
    func get() -> Result<T, Error>? { lock.withLock { result } }
    func finish(_ overall: Result<Void, Error>) -> Result<T, Error> {
        switch (overall, get()) {
        case (.success, .some(let value)): return value
        case (.failure, .some(.failure(let error))): return .failure(error)
        case (.failure(let error), _): return .failure(error)
        default: return .failure(ProbeFailure.unavailable)
        }
    }
}
