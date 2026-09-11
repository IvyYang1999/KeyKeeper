import Foundation
import Security

/// IO seam between the blob store and the real keychain, so unit tests (and the
/// pre-commit hook that runs them) never touch the user's login keychain.
public protocol KeychainBlobIO: AnyObject, Sendable {
    /// Returns the stored blob, or nil when no item exists yet.
    func readBlob() throws -> Data?
    /// Never create after a successful read, or overwrite an item created by another writer.
    func writeBlob(_ data: Data, replacingExisting: Bool) throws
}

/// Real keychain IO: one generic-password item holds the whole credential store.
///
/// One item instead of one per field keeps the ACL story sane: a user who builds
/// from source with an ad-hoc signature gets at most ONE authorization prompt per
/// rebuild, not one per credential (the July popup storms came from per-field items).
public final class SecItemBlobIO: KeychainBlobIO, @unchecked Sendable {
    /// Test seam: E2E runs override this so an isolated item is used and cleaned up.
    public static let serviceEnvironmentKey = "KEYKEEPER_KEYCHAIN_SERVICE"
    public static let defaultService = "com.keykeeper.credentials"

    private let service: String
    private let account = "keykeeper"
    private let updateItem: (CFDictionary, CFDictionary) -> OSStatus
    private let addItem: (CFDictionary) -> OSStatus

    public convenience init(service: String? = nil) {
        self.init(service: service
            ?? ProcessInfo.processInfo.environment[Self.serviceEnvironmentKey]
            ?? Self.defaultService,
                  updateItem: { SecItemUpdate($0, $1) },
                  addItem: { SecItemAdd($0, nil) })
    }

    /// System-call seam for checking update/create failure paths without accessing Keychain.
    init(service: String, updateItem: @escaping (CFDictionary, CFDictionary) -> OSStatus,
         addItem: @escaping (CFDictionary) -> OSStatus) {
        self.service = service
        self.updateItem = updateItem
        self.addItem = addItem
    }

    public func readBlob() throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedData }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.retrieveFailed(status)
        }
    }

    public func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if replacingExisting {
            // Update-only: an item disappearing between read and write is an error.
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = updateItem(match as CFDictionary, update as CFDictionary)
            guard updateStatus != errSecItemNotFound else { throw CredentialStorageError.missingStore }
            guard updateStatus == errSecSuccess else { throw KeychainError.saveFailed(updateStatus) }
            return
        }

        var add = match
        add[kSecValueData as String] = data
        let addStatus = addItem(add as CFDictionary)
        guard addStatus == errSecSuccess else {
            throw KeychainError.saveFailed(addStatus)
        }
    }
}

/// Field-level credential-value store over a single keychain blob.
///
/// The blob is a versioned JSON document `{"version":1,"credentials":{id:{field:value}}}`.
/// Metadata (labels, notes, field names, security level) stays in meta.json exactly as
/// before; only secret values live here.
public final class KeychainBlobStore: @unchecked Sendable {
    struct Blob: Codable {
        var version: Int
        var credentials: [String: [String: String]]

        static let empty = Blob(version: 1, credentials: [:])
    }

    private let io: KeychainBlobIO
    private let mutex = NSLock()
    private let loadMetadata: () throws -> MetaFile
    private var hasObservedStore = false

    /// Production wiring: metadata restored without its Keychain must never create an empty store.
    public convenience init() {
        self.init(io: SecItemBlobIO(), loadMetadata: { try MetaStore.default.load() })
    }

    /// Explicit IO injection for tests and the legacy migration that initializes the new store.
    public init(io: KeychainBlobIO, loadMetadata: @escaping () throws -> MetaFile = { MetaFile() }) {
        self.io = io
        self.loadMetadata = loadMetadata
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        try withLock {
            guard let value = try loadBlob().credentials[credentialId]?[fieldName] else {
                throw KeychainError.notFound
            }
            return value
        }
    }

    public func save(credentialId: String, fieldName: String, value: String) throws {
        try withLock {
            var blob = try loadBlob()
            blob.credentials[credentialId, default: [:]][fieldName] = value
            try store(blob)
        }
    }

    /// Explicit recovery/import path: check and insert under the same lock, never replace.
    public func saveMissing(credentialId: String, fieldName: String, value: String) throws {
        try withLock {
            var blob = try loadBlob()
            guard blob.credentials[credentialId]?[fieldName] == nil else {
                throw ClipboardSaveError.valueExists
            }
            blob.credentials[credentialId, default: [:]][fieldName] = value
            try store(blob)
        }
    }

    /// Partial historical coverage is not a reason to reject a disjoint append.
    /// Validate the store and both ID inventories under the same lock, then write all fields once.
    public func createCredential(credentialId: String, values: [String: String]) throws {
        try withLock {
            guard !credentialId.isEmpty, !values.isEmpty,
                  values.allSatisfy({ !$0.key.isEmpty && !$0.value.isEmpty }) else {
                throw ClipboardSaveError.invalidTarget
            }
            var blob = try loadBlob()
            let meta = try loadMetadata()
            guard meta.version == 1 else { throw ClipboardSaveError.storageUnavailable }
            guard meta.credentials[credentialId] == nil, blob.credentials[credentialId] == nil else {
                throw ClipboardSaveError.valueExists
            }
            blob.credentials[credentialId] = values
            try store(blob)
        }
    }

    public func delete(credentialId: String, fieldName: String) throws {
        try withLock {
            var blob = try loadBlob()
            guard blob.credentials[credentialId]?[fieldName] != nil else {
                throw KeychainError.notFound
            }
            blob.credentials[credentialId]?.removeValue(forKey: fieldName)
            if blob.credentials[credentialId]?.isEmpty == true {
                blob.credentials.removeValue(forKey: credentialId)
            }
            try store(blob)
        }
    }

    /// Field names per credential — used by migration verification. Never exposes values.
    public func fieldNamesByCredential() throws -> [String: Set<String>] {
        try withLock {
            try loadBlob().credentials.mapValues { Set($0.keys) }
        }
    }

    /// Called once before a GUI mutation, while metadata still describes the pre-edit values.
    /// Per-field deletion intentionally precedes metadata commits, so don't repeat this
    /// inventory check halfway through a multi-field edit.
    public func validateStorage() throws {
        try withLock {
            let blob = try loadBlob()
            let meta = try loadMetadata()
            for (id, credential) in meta.credentials {
                for (field, metadata) in credential.fields where metadata.secret {
                    guard blob.credentials[id]?[field] != nil else {
                        throw CredentialStorageError.incompleteStore
                    }
                }
            }
        }
    }

    private func loadBlob() throws -> Blob {
        guard let data = try io.readBlob() else {
            let meta = try loadMetadata()
            let expectsValues = meta.credentials.values.contains { credential in
                credential.fields.values.contains { $0.secret }
            }
            guard !hasObservedStore && !expectsValues else { throw CredentialStorageError.missingStore }
            return .empty
        }
        hasObservedStore = true
        do {
            let blob = try JSONDecoder().decode(Blob.self, from: data)
            guard blob.version == 1 else { throw KeychainError.unexpectedData }
            return blob
        } catch {
            // A corrupt store must never masquerade as "empty": overwriting it from the
            // empty state would silently destroy every stored value.
            throw KeychainError.unexpectedData
        }
    }

    private func store(_ blob: Blob) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(blob)
        } catch {
            throw KeychainError.unexpectedData
        }
        try io.writeBlob(data, replacingExisting: hasObservedStore)
        hasObservedStore = true
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try operation()
    }
}

/// The drop-in replacement for the age SessionManager: same CRUD surface, but there is
/// no lock and no passphrase. The OS keychain unlocks with the user's login; that is the
/// entire session model (decision 2026-09-03, 方案-20260903-去passphrase化 option A).
public final class KeychainCredentialService: @unchecked Sendable {
    private let store: KeychainBlobStore

    public init(store: KeychainBlobStore = KeychainBlobStore()) {
        self.store = store
    }

    public func status() -> SessionStatus {
        .unlocked(expiresAt: nil)
    }

    public func validateStorage() throws {
        try store.validateStorage()
    }

    public func fieldNamesByCredential() throws -> [String: Set<String>] {
        try store.fieldNamesByCredential()
    }

    public func saveMissing(credentialId: String, fieldName: String, value: String) throws {
        try store.saveMissing(credentialId: credentialId, fieldName: fieldName, value: value)
    }

    public func createCredential(credentialId: String, values: [String: String], security: SecurityLevel) throws {
        _ = security
        try store.createCredential(credentialId: credentialId, values: values)
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        try store.retrieve(credentialId: credentialId, fieldName: fieldName)
    }

    /// `security` is metadata and lives in meta.json (written by the caller); the
    /// keychain item itself has no per-credential access levels.
    public func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws {
        _ = security
        try store.save(credentialId: credentialId, fieldName: fieldName, value: value)
    }

    public func delete(credentialId: String, fieldName: String) throws {
        try store.delete(credentialId: credentialId, fieldName: fieldName)
    }
}

extension KeychainCredentialService: CredentialSessionManaging {}
