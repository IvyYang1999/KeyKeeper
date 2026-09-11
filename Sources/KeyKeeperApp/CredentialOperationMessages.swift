import KeyKeeperCore

enum CredentialOperationMessages {
    static func requireWritableStorage(_ session: any CredentialSessionManaging) throws {
        try requireUnlocked(session)
        try session.validateStorage()
    }

    static func requireUnlocked(_ session: any CredentialSessionManaging) throws {
        guard case .unlocked = session.status() else {
            throw SessionManagerError.locked
        }
    }

    static func failure(action: String, fallbackPrefix: String, error: Error) -> String {
        if error is SessionManagerError {
            return L("Unlock KeyKeeper first to \(action).")
        }
        return "\(fallbackPrefix): \(AppL10n.text(error.localizedDescription))"
    }
}
