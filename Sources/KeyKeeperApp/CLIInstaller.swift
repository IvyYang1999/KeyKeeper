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

    struct Target: Equatable {
        let path: String
        let needsAdmin: Bool
    }

    /// Where to put it.
    ///
    /// 【曾经的 bug】this used to be hard-coded to /usr/local/bin. On a Mac where that directory
    /// does not exist and `keykeeper` lives in /opt/homebrew/bin, "update" installed a fresh copy
    /// somewhere the shell never looks, while the stale one kept answering — which looks exactly
    /// like the button doing nothing.
    ///
    /// So: replace the one that is already there, and only ask for an administrator password
    /// when the directory genuinely needs it.
    static func preferredTarget(
        existing: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        writableDirectory: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> Target {
        let candidates = CLIInstallState.searchPaths
        let chosen = candidates.first(where: existing) ?? candidates.first(where: {
            writableDirectory(($0 as NSString).deletingLastPathComponent)
        }) ?? targetPath
        let directory = (chosen as NSString).deletingLastPathComponent
        return Target(path: chosen, needsAdmin: !writableDirectory(directory))
    }

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
        let target = preferredTarget()
        let script = installScript(bundleCLI: bundleCLI, target: target.path)
        guard target.needsAdmin else {
            // Nothing here needs privileges: just make the link.
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return "CLI install failed."
            }
            return process.terminationStatus == 0 ? nil : "CLI install failed."
        }
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
            .executeAndReturnError(&error)
        return error == nil ? nil : "CLI install cancelled or failed."
    }
}
