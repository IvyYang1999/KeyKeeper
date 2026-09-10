import Foundation

public enum CredentialStorageError: Error, LocalizedError {
    case missingStore
    case incompleteStore

    public var errorDescription: String? {
        switch self {
        case .missingStore:
            return "The credential store is unavailable. Existing credential records were found, or this store was previously open. Changes are blocked. Restore and unlock the original Keychain before saving."
        case .incompleteStore:
            return "Some saved credentials are missing their values. Changes are blocked to protect recovery. Restore the original Keychain before editing credentials."
        }
    }
}
