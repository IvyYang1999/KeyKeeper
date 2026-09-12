import Foundation

/// Session state as reported over IPC. With the Keychain store (decision 2026-09-03)
/// the session is always unlocked: logging into the Mac IS the unlock. The `.locked`
/// case remains for wire compatibility with the retired age-vault model.
public enum SessionStatus: Sendable, Equatable {
    case locked
    case unlocked(expiresAt: Date?)
}

public enum SessionManagerError: Error, LocalizedError, Sendable {
    case locked

    public var errorDescription: String? {
        switch self {
        case .locked:
            return "The credential session is locked"
        }
    }
}

/// Secret CRUD surface shared by GUI data models and the process-wide store owner.
public protocol CredentialSessionManaging: AnyObject {
    func inspectValueInventory() throws -> [String: Set<String>]
    func status() -> SessionStatus
    /// Check the pre-edit inventory before any value or metadata mutation begins.
    func validateStorage() throws
    /// Create a whole new ID in one write; must never replace existing or orphan values.
    func createCredential(credentialId: String, values: [String: String], security: SecurityLevel) throws
    func retrieve(credentialId: String, fieldName: String) throws -> String
    func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws
    func delete(credentialId: String, fieldName: String) throws
    /// Rename support: copy values to new names keeping the originals, then drop the originals.
    func copyValues(fromCredentialId: String, toCredentialId: String, fieldMap: [String: String]) throws
    func dropValues(credentialId: String, fieldNames: [String]) throws
}

extension CredentialSessionManaging {
    public func inspectValueInventory() throws -> [String: Set<String>] { throw KeychainError.unexpectedData }
    // Legacy/test session providers have no split metadata/blob inventory.
    public func validateStorage() throws {}
    // Older providers must opt into atomic create; never emulate it with overwrite-capable saves.
    public func createCredential(credentialId: String, values: [String: String], security: SecurityLevel) throws {
        throw ClipboardSaveError.storageUnavailable
    }
    // Renames need the two-step copy/drop; providers without it refuse rather than emulate.
    public func copyValues(fromCredentialId: String, toCredentialId: String, fieldMap: [String: String]) throws {
        throw ClipboardSaveError.storageUnavailable
    }
    public func dropValues(credentialId: String, fieldNames: [String]) throws {
        throw ClipboardSaveError.storageUnavailable
    }
}
