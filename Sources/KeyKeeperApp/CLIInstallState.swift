import Foundation

/// What the setup screen knows about the installed `keykeeper` binary.
enum CLIInstallState: Equatable {
    case missing
    /// Installed, but built from a different commit than this app.
    case stale(installed: String)
    case current(installed: String)

    static let searchPaths = ["/usr/local/bin/keykeeper", "/opt/homebrew/bin/keykeeper"]

    static func derive(installedVersion: String?, appVersion: String) -> CLIInstallState {
        guard let installedVersion, !installedVersion.isEmpty else { return .missing }
        // "keykeeper unknown" means the build had no git metadata; don't call that stale.
        if installedVersion == appVersion || appVersion.hasSuffix("unknown") || installedVersion.hasSuffix("unknown") {
            return .current(installed: installedVersion)
        }
        return .stale(installed: installedVersion)
    }

    var isUsable: Bool {
        if case .missing = self { return false }
        return true
    }

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    /// Runs `<path> --version` for the first binary found on the search paths.
    static func probe(appVersion: String, paths: [String] = searchPaths) -> CLIInstallState {
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return .missing
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .missing
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return derive(installedVersion: version, appVersion: appVersion)
    }

    /// The Claude Code skill is a directory skill (`skills/keykeeper/SKILL.md`); the
    /// flat file is what older instructions produced and still counts.
    static func skillInstalled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let candidates = [
            home.appendingPathComponent(".claude/skills/keykeeper/SKILL.md"),
            home.appendingPathComponent(".claude/skills/keykeeper.md"),
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
