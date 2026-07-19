import KeyKeeperCore

enum CredentialOperationMessages {
    static func requireUnlocked(_ session: any CredentialSessionManaging) throws {
        guard case .unlocked = session.status() else {
            throw SessionManagerError.locked
        }
    }

    static func failure(action: String, fallbackPrefix: String, error: Error) -> String {
        if error is SessionManagerError {
            return "Unlock KeyKeeper first to \(action)."
        }
        return "\(fallbackPrefix): \(error.localizedDescription)"
    }
}
