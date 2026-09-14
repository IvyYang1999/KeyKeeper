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
        case notRegistered
        /// The registration exists but points somewhere else — somebody rewrote the file.
        case tamperedWith
        /// Registered by KeyKeeper, for where it used to live.
        case moved
        /// KeyKeeper's side is wired up. Deliberately not called "connected": this file is one
        /// KeyKeeper wrote, and Chrome never writes back to it. If the extension is later removed
        /// in Chrome, nothing here changes — so the screen must not claim Chrome is ready.
        case registered(String)
    }

    var extensionFolder: URL?
    var launcher: URL?
    var manifestURL: URL
    /// The ID Chrome will give the bundled extension, derived from the `key` pinned in its
    /// manifest. Constant, so nobody has to copy 32 letters out of chrome://extensions.
    var expectedExtensionID: String?

    static func production(bundle: Bundle = .main) -> BrowserExtensionSetup {
        let resources = bundle.resourceURL
        let folder = resources?.appendingPathComponent("browser-extension")
        return BrowserExtensionSetup(
            extensionFolder: folder,
            launcher: resources?.appendingPathComponent("browser-native-host"),
            manifestURL: BrowserHostRegistration.manifestURL(),
            expectedExtensionID: folder.flatMap(extensionID(inManifestAt:))
        )
    }

    static func extensionID(inManifestAt folder: URL) -> String? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["key"] as? String
        else { return nil }
        return BrowserHostRegistration.extensionID(publicKeyBase64: key)
    }

    var connection: Connection {
        guard let extensionFolder, let launcher,
              FileManager.default.fileExists(atPath: extensionFolder.path),
              FileManager.default.fileExists(atPath: launcher.path)
        else { return .missingFromApp }
        // The file's own extension ID is taken as intended: re-registering for a different extension
        // is a supported way out (a development copy, say). What must match is everything else —
        // above all `path`, which decides where Chrome sends the cookies.
        switch BrowserHostRegistration.registrationState(at: manifestURL, expectedLauncher: launcher.path,
                                                         expectedExtensionID: nil) {
        case .intact(let id): return .registered(id)
        case .moved: return .moved
        case .tampered: return .tamperedWith
        case nil: return .notRegistered
        }
    }

    /// Registering over a tampered file has to replace it. Install is create-only, so the plain
    /// "Register" button could never repair a tampered registration — it failed because the file
    /// exists. 【独立审计 2026-09-13】
    static func registrationReplacesExisting(_ connection: Connection) -> Bool {
        connection == .tamperedWith || connection == .moved
    }

    /// Registers this Mac's Chrome to talk to exactly one extension. Create-only by default: an
    /// existing registration for a different extension is reported, never replaced silently.
    /// `replacingExisting` is the way back out, and only ever runs from an explicit click.
    func connect(extensionID: String? = nil, replacingExisting: Bool = false) throws {
        guard let launcher else { throw BrowserHostRegistrationError.invalidLauncherPath }
        guard let wanted = (extensionID ?? expectedExtensionID)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !wanted.isEmpty
        else { throw BrowserHostRegistrationError.invalidExtensionID }
        let manifest = try BrowserHostRegistration.manifest(extensionID: wanted, launcher: launcher.path)
        if replacingExisting { try? FileManager.default.removeItem(at: manifestURL) }
        try BrowserHostRegistration.install(manifest, at: manifestURL)
    }

    func revealExtensionFolder() {
        guard let extensionFolder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([extensionFolder])
    }
}
