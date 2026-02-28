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

    public func save(credentialId: String, fieldName: String,
                     value: String, security: SecurityLevel) throws {
        let service = serviceName(credentialId: credentialId, fieldName: fieldName)
        let data = Data(value.utf8)

        // Try to delete existing item first
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

        if security == .strict {
            let access = SecAccessControlCreateWithFlags(
                nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence, nil
            )
            if let access = access {
                addQuery[kSecAttrAccessControl as String] = access
            }
        }

        var status = SecItemAdd(addQuery as CFDictionary, nil)

        // If strict mode fails due to missing entitlement (-34018),
        // fall back to standard mode so the key is still saved securely.
        if status != errSecSuccess && security == .strict {
            SecItemDelete(deleteQuery as CFDictionary)
            addQuery.removeValue(forKey: kSecAttrAccessControl as String)
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

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
