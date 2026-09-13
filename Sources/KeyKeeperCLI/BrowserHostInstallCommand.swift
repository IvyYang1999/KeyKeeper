import Foundation
import ArgumentParser
import KeyKeeperCore

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
        let target = BrowserHostRegistration.manifestURL()
        try BrowserHostRegistration.install(manifest, at: target)
        print("Chrome native host registered for the selected extension. No website permission or login state was imported.")
        print("Extension files: \(bundle.appendingPathComponent("Contents/Resources/browser-extension").path)")
    }
}
