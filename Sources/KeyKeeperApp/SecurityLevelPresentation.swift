import KeyKeeperCore

/// Human copy for `SecurityLevel`.
///
/// The level is presented as "who can use these keys", not as a safety scale. Calling the
/// background-friendly level "less secure" steered first-time users into `strict`, which
/// then failed for every cron job and agent they set up.
enum SecurityLevelPresentation {
    /// The level new credentials start with. Background callers are still gated by the
    /// per-caller approval flow, so this is the right default for automation-first users.
    static let defaultLevel: SecurityLevel = .standard

    static let sectionTitle = "Who can use these keys"

    /// Label for the toggle that switches a credential to `strict`.
    static let strictToggleLabel = "Ask me every time a new terminal session uses these keys"

    static func badge(_ level: SecurityLevel) -> String {
        switch level {
        case .standard: return "Background OK"
        case .strict: return "Ask every time"
        }
    }

    static func symbolName(_ level: SecurityLevel) -> String {
        switch level {
        case .standard: return "bolt.horizontal.circle"
        case .strict: return "hand.raised.circle"
        }
    }

    static func title(_ level: SecurityLevel) -> String {
        switch level {
        case .standard: return "Approve each caller once"
        case .strict: return "Approve every terminal session"
        }
    }

    static func detail(_ level: SecurityLevel) -> String {
        switch level {
        case .standard:
            return "Scripts, cron jobs and AI agents can use these keys after you approve them once in KeyKeeper. Choose this for anything that runs in the background."
        case .strict:
            return "Every new terminal session has to be approved in the KeyKeeper window while you are at the Mac. Not suitable for cron jobs or unattended agents."
        }
    }
}
