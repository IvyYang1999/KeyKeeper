import CryptoKit
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

    /// Chrome's extension ID for a pinned manifest `key`: the first 16 bytes of the SHA-256 of
    /// the DER public key, with each hex digit mapped 0→a … f→p.
    ///
    /// Without a pinned key Chrome derives the ID from the extension's *path* instead, so the ID
    /// changes if KeyKeeper.app ever moves — and the native host's allowed_origins, which names
    /// exactly one ID, silently stops matching. Pinning the key makes it a constant, which also
    /// means the app can register the host itself instead of asking someone to copy 32 letters.
    public static func extensionID(publicKeyBase64: String) -> String? {
        guard let der = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              !der.isEmpty else { return nil }
        let digest = SHA256.hash(data: der)
        let scalars = digest.prefix(16).flatMap { byte -> [Character] in
            [Character(UnicodeScalar(UInt8(ascii: "a") + (byte >> 4))),
             Character(UnicodeScalar(UInt8(ascii: "a") + (byte & 0x0F)))]
        }
        return String(scalars)
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
    /// The extension this Mac is wired to, and whether the registration still points at the
    /// launcher it was written for.
    ///
    /// 【安全审计 2026-09-13】Nothing ever re-read this file after writing it. It is an ordinary
    /// 0600 file, and a process running as the same user can unlink and rewrite it — pointing
    /// `path` at its own program, so Chrome hands the cookies there instead, while KeyKeeper
    /// keeps saying "registered". The extension ID was never the interesting field.
    public static func registration(at target: URL = manifestURL(),
                                    expectedLauncher: String?) -> (id: String, intact: Bool)? {
        guard let id = registeredExtensionID(at: target) else { return nil }
        guard let expectedLauncher else { return (id, true) }
        guard let data = try? Data(contentsOf: target),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = object["path"] as? String
        else { return (id, false) }
        return (id, path == expectedLauncher)
    }

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
