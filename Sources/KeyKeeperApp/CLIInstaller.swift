import AppKit
import Foundation

/// Copies the bundled CLI to /usr/local/bin with an administrator prompt.
enum CLIInstaller {
    static let targetPath = "/usr/local/bin/keykeeper"

    /// Returns an error message, or nil on success.
    static func installWithAdminPrivileges() -> String? {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/keykeeper").path
        guard FileManager.default.isExecutableFile(atPath: bundleCLI) else {
            return "This build has no bundled CLI (run from the .app in Applications)."
        }
        let escapedPath = bundleCLI.replacingOccurrences(of: "'", with: "'\\''")
        let script = "cp '\(escapedPath)' \(targetPath) && chmod +x \(targetPath)"
        let fullScript = "do shell script \"\(script)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: fullScript)?.executeAndReturnError(&error)
        return error == nil ? nil : "CLI install cancelled or failed."
    }
}
