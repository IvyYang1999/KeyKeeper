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
    func status() -> SessionStatus
    func retrieve(credentialId: String, fieldName: String) throws -> String
    func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws
    func delete(credentialId: String, fieldName: String) throws
}
