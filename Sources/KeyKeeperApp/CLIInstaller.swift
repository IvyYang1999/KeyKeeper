import AppKit
import Foundation

/// Puts `keykeeper` on the PATH, pointing at the CLI inside this app bundle.
///
/// It used to copy the binary. That made every app update leave a stale copy behind, and the
/// only way to notice was a row buried in Settings that asked for the administrator password
/// again. A symlink follows the app: update KeyKeeper and the command-line tool is already the
/// new one, with no second prompt, ever.
enum CLIInstaller {
    static let targetPath = "/usr/local/bin/keykeeper"

    /// The shell run with administrator privileges. Built separately so it can be read and
    /// tested without asking anyone for their password.
    static func installScript(bundleCLI: String, target: String) -> String {
        let quoted = "'" + bundleCLI.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let directory = (target as NSString).deletingLastPathComponent
        // -f replaces whatever is there, including the copy older versions installed.
        return "mkdir -p \(directory) && ln -sfn \(quoted) \(target)"
    }

    /// Returns an error message, or nil on success.
    static func installWithAdminPrivileges() -> String? {
        let bundleCLI = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/keykeeper").path
        guard FileManager.default.isExecutableFile(atPath: bundleCLI) else {
            return "This build has no bundled CLI (run from the .app in Applications)."
        }
        let script = installScript(bundleCLI: bundleCLI, target: targetPath)
        let fullScript = "do shell script \"\(script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: fullScript)?.executeAndReturnError(&error)
        return error == nil ? nil : "CLI install cancelled or failed."
    }
}
