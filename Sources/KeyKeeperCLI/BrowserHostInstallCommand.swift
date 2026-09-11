import Foundation
import ArgumentParser

enum BrowserHostRegistration {
    static func manifest(extensionID: String, launcher: String) throws -> Data {
        guard extensionID.range(of: #"^[a-p]{32}$"#, options: .regularExpression) != nil,
              launcher.hasPrefix("/"), !launcher.contains("\n"), !launcher.contains("\0") else {
            throw ValidationError("An exact Chrome extension ID and absolute native-host path are required.")
        }
        return try JSONSerialization.data(withJSONObject: [
            "name": "com.keykeeper.browser_sessions", "description": "KeyKeeper selected website sessions",
            "path": launcher, "type": "stdio", "allowed_origins": ["chrome-extension://" + extensionID + "/"]
        ], options: [.prettyPrinted, .sortedKeys])
    }
    static func install(_ bytes: Data, at target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        if fm.fileExists(atPath: target.path) {
            guard try !target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink!,
                  try Data(contentsOf: target) == bytes else {
                throw ValidationError("A different native host is already registered. It was not overwritten.")
            }
            return
        }
        try bytes.write(to: target, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

struct BrowserHostInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "browser-install-host",
        abstract: "Explicitly connect one installed Chrome extension to this Mac's KeyKeeper App.")
    @Option(name: .long, help: "Exact 32-character ID shown at chrome://extensions.") var extensionID: String
    @Option(name: .long, help: "Signed App bundle containing the native host.") var app = "/Applications/KeyKeeper.app"
    mutating func run() throws {
        let bundle = URL(fileURLWithPath: app).standardizedFileURL
        let launcher = bundle.appendingPathComponent("Contents/Resources/browser-native-host")
        let cli = bundle.appendingPathComponent("Contents/MacOS/keykeeper")
        guard app.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: launcher.path),
              FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw ValidationError("Install the KeyKeeper App with browser-session support first.")
        }
        let manifest = try BrowserHostRegistration.manifest(extensionID: extensionID, launcher: launcher.path)
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.keykeeper.browser_sessions.json")
        try BrowserHostRegistration.install(manifest, at: target)
        print("Chrome native host registered for the selected extension. No website permission or login state was imported.")
        print("Extension files: \(bundle.appendingPathComponent("Contents/Resources/browser-extension").path)")
    }
}
