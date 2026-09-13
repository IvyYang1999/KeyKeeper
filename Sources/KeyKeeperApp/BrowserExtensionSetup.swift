import AppKit
import KeyKeeperCore

/// Getting Chrome connected, from inside the app.
///
/// The extension is not on the Chrome Web Store — it ships as a folder inside KeyKeeper.app and
/// has to be loaded by hand from `chrome://extensions` with Developer mode on. That is three
/// steps the person previously had to find in a document; the Website-sessions page said only
/// "use the KeyKeeper extension", naming something they had no way to obtain.
///
/// This does not hide any of that. It hands over the folder, and it takes over the one step that
/// genuinely belongs to the app: registering the native-messaging host so Chrome will talk to it.
struct BrowserExtensionSetup: Equatable {
    enum Connection: Equatable {
        /// Built without the extension: telling this person to go load it would be a lie.
        case missingFromApp
        case notConnected
        case connected(String)
    }

    var extensionFolder: URL?
    var launcher: URL?
    var manifestURL: URL

    static func production(bundle: Bundle = .main) -> BrowserExtensionSetup {
        let resources = bundle.resourceURL
        return BrowserExtensionSetup(
            extensionFolder: resources?.appendingPathComponent("browser-extension"),
            launcher: resources?.appendingPathComponent("browser-native-host"),
            manifestURL: BrowserHostRegistration.manifestURL()
        )
    }

    var connection: Connection {
        guard let extensionFolder, let launcher,
              FileManager.default.fileExists(atPath: extensionFolder.path),
              FileManager.default.fileExists(atPath: launcher.path)
        else { return .missingFromApp }
        if let id = BrowserHostRegistration.registeredExtensionID(at: manifestURL) {
            return .connected(id)
        }
        return .notConnected
    }

    /// Registers this Mac's Chrome to talk to exactly one extension. Create-only: an existing
    /// registration for a different extension is reported, never replaced.
    func connect(extensionID: String) throws {
        guard let launcher else { throw BrowserHostRegistrationError.invalidLauncherPath }
        let id = extensionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try BrowserHostRegistration.manifest(extensionID: id, launcher: launcher.path)
        try BrowserHostRegistration.install(manifest, at: manifestURL)
    }

    func revealExtensionFolder() {
        guard let extensionFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }
}
