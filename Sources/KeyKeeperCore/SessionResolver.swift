import Foundation

public struct SessionInfo: Sendable {
    public let id: String?
    public let label: String

    public init(id: String?, label: String) {
        self.id = id
        self.label = label
    }
}

public enum SessionResolver {
    /// Resolve session ID from environment variables.
    /// Priority: TERM_SESSION_ID > ITERM_SESSION_ID > KEYKEEPER_SESSION_ID
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> SessionInfo {
        let envKeys = ["TERM_SESSION_ID", "ITERM_SESSION_ID", "KEYKEEPER_SESSION_ID"]

        for key in envKeys {
            if let value = environment[key], !value.isEmpty {
                let label = humanLabel(source: key, value: value, environment: environment)
                return SessionInfo(id: value, label: label)
            }
        }

        return SessionInfo(id: nil, label: "Unknown terminal")
    }

    private static func humanLabel(source: String, value: String,
                                   environment: [String: String]) -> String {
        // Try to build a readable label like "Terminal (tab 3)" or "iTerm2 session"
        let app: String
        if source == "ITERM_SESSION_ID" {
            app = "iTerm2"
        } else if let termProgram = environment["TERM_PROGRAM"] {
            app = termProgram
        } else {
            app = "Terminal"
        }

        // Use a short prefix of the session ID for disambiguation
        let shortId = String(value.prefix(8))
        return "\(app) (\(shortId))"
    }
}
