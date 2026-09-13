import Foundation

public enum BrowserHostRegistrationError: Error, Equatable, LocalizedError {
    case invalidExtensionID
    case invalidLauncherPath
    case differentHostRegistered

    public var errorDescription: String? {
        switch self {
        case .invalidExtensionID:
            return "A Chrome extension ID is exactly 32 letters a–p, shown at chrome://extensions."
        case .invalidLauncherPath:
            return "The native host path must be absolute. Install the KeyKeeper App with browser-session support first."
        case .differentHostRegistered:
            return "A different native host is already registered for KeyKeeper. It was not overwritten."
        }
    }
}

/// Connects exactly one installed Chrome extension to this Mac's KeyKeeper App.
///
/// Chrome will only talk to a native program that the user has registered by hand, and only to
/// the one extension ID named in that registration. This is the whole trust anchor for website
/// sessions, so it is create-only: an existing registration pointing somewhere else is reported,
/// never replaced.
public enum BrowserHostRegistration {
    public static let hostName = "com.keykeeper.browser_sessions"

    /// Where Chrome looks for it, in this user's own Chrome profile directory.
    public static func manifestURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/\(hostName).json")
    }

    public static func manifest(extensionID: String, launcher: String) throws -> Data {
        guard extensionID.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil else {
            throw BrowserHostRegistrationError.invalidExtensionID
        }
        guard launcher.hasPrefix("/"), !launcher.contains("\n"), !launcher.contains("\0") else {
            throw BrowserHostRegistrationError.invalidLauncherPath
        }
        return try JSONSerialization.data(withJSONObject: [
            "name": hostName, "description": "KeyKeeper selected website sessions",
            "path": launcher, "type": "stdio", "allowed_origins": ["chrome-extension://" + extensionID + "/"]
        ], options: [.prettyPrinted, .sortedKeys])
    }

    public static func install(_ bytes: Data, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: target.path) {
            guard try !target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink!,
                  try Data(contentsOf: target) == bytes else {
                throw BrowserHostRegistrationError.differentHostRegistered
            }
            return
        }
        try bytes.write(to: target, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// The extension ID this Mac is currently wired to, if any. Lets the app say "connected"
    /// instead of asking the person to remember whether they ever ran the setup step.
    public static func registeredExtensionID(at target: URL = manifestURL()) -> String? {
        guard let data = try? Data(contentsOf: target),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let origins = object["allowed_origins"] as? [String], origins.count == 1,
              let origin = origins.first
        else { return nil }
        let id = origin
            .replacingOccurrences(of: "chrome-extension://", with: "")
            .replacingOccurrences(of: "/", with: "")
        return id.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil ? id : nil
    }
}
