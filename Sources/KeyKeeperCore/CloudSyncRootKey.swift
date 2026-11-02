import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Immutable random-ID encryption roots alone synchronize through iCloud Keychain.
/// Credential values, grants and sync recovery state remain nonsynchronizable local items.
enum CloudSyncRootKey {
    static func query(binding: CloudSyncBinding, vault: UUID, key: UUID, scope: CloudSyncScope) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        let accountHash = SHA256.hash(data: Data(binding.accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "\(scope.rootServicePrefix).\(binding.environment).\(accountHash).\(vault.uuidString)",
                kSecAttrAccount as String: key.uuidString,
                kSecAttrAccessGroup as String: StorageIdentity.accessGroup,
                kSecAttrSynchronizable as String: true,
                kSecUseDataProtectionKeychain as String: true,
                kSecUseAuthenticationContext as String: context]
    }
    static func read(binding: CloudSyncBinding, vault: UUID, key: UUID, scope: CloudSyncScope) throws -> SymmetricKey? {
        var q = query(binding: binding, vault: vault, key: key, scope: scope)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data, bytes.count == 32 else { throw CloudSyncError.unavailable }
        return SymmetricKey(data: bytes)
    }
    static func createOrRead(binding: CloudSyncBinding, vault: UUID, key: UUID, scope: CloudSyncScope) throws -> SymmetricKey {
        if let existing = try read(binding: binding, vault: vault, key: key, scope: scope) { return existing }
        let candidate = SymmetricKey(size: .bits256)
        var q = query(binding: binding, vault: vault, key: key, scope: scope)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecValueData as String] = candidate.withUnsafeBytes { Data($0) }
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem,
              let restored = try read(binding: binding, vault: vault, key: key, scope: scope) else { throw CloudSyncError.unavailable }
        if status == errSecSuccess {
            guard restored.withUnsafeBytes({ Data($0) }) == candidate.withUnsafeBytes({ Data($0) }) else {
                throw CloudSyncError.stateUnavailable
            }
        }
        return restored
    }
}
