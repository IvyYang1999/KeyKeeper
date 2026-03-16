import Foundation
import Security

public enum KeychainError: Error, LocalizedError {
    case saveFailed(OSStatus)
    case notFound
    case retrieveFailed(OSStatus)
    case deleteFailed(OSStatus)
    case unexpectedData

    public var errorDescription: String? {
        switch self {
        case .saveFailed(let s): return "Keychain save failed: \(s)"
        case .notFound: return "Key not found in Keychain"
        case .retrieveFailed(let s): return "Keychain retrieve failed: \(s)"
        case .deleteFailed(let s): return "Keychain delete failed: \(s)"
        case .unexpectedData: return "Unexpected data format in Keychain"
        }
    }
}

public final class KeychainService: Sendable {
    public init() {}

    private func serviceName(credentialId: String, fieldName: String) -> String {
        "keykeeper.\(credentialId).\(fieldName)"
    }

    /// Create a SecAccess that allows ANY application to access the item
    /// without triggering per-app ACL prompts.
    private func createPermissiveAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("KeyKeeper" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }

        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }

        for acl in acls {
            var appList: CFArray?
            var description: CFString?
            var promptSelector = SecKeychainPromptSelector()
            SecACLCopyContents(acl, &appList, &description, &promptSelector)

            // nil applicationList = any application can access
            SecACLSetContents(acl, nil, description ?? "" as CFString, promptSelector)
        }

        return access
    }

    public func save(credentialId: String, fieldName: String,
                     value: String, security: SecurityLevel) throws {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let data = Data(value.utf8)

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        var addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
            kSecValueData as String: data,
        ]

        // Use permissive access so any KeyKeeper binary (CLI, App, debug, release)
        // can read/write without per-app ACL prompts.
        if let access = createPermissiveAccess() {
            addQuery[kSecAttrAccess as String] = access
        }

        let status = SecItemAdd(addQuery as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status != errSecItemNotFound else {
            throw KeychainError.notFound
        }
        guard status == errSecSuccess else {
            throw KeychainError.retrieveFailed(status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.unexpectedData
        }
        return string
    }

    /// Retrieve and re-save with permissive ACL if the entry has restrictive access.
    /// Call this once per entry to fix old entries that trigger per-app ACL prompts.
    public func healAccess(credentialId: String, fieldName: String) {
        guard let value = try? retrieve(credentialId: credentialId, fieldName: fieldName) else { return }
        try? save(credentialId: credentialId, fieldName: fieldName, value: value, security: .standard)
    }

    public func delete(credentialId: String, fieldName: String) throws {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "keykeeper",
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}
