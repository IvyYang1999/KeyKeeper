import Foundation

/// What the setup screen knows about the installed `keykeeper` binary.
///
/// Each case is one thing that was actually checked. A green state means the command ran and is
/// this app's build; it says nothing about agent approvals or whether a provider accepts a key.
enum CLIInstallState: Equatable {
    /// No `keykeeper` on the search paths.
    case missing
    /// An entry exists, but `--version` did not run, failed, or answered nothing.
    case failed(path: String)
    /// It runs and reports a different, known build than this app.
    case stale(installed: String)
    /// It runs, but its build cannot be confirmed because a version is unknown on one side.
    /// Pointing at this app's own CLI is reported alongside; it does not make the version known.
    case unverified(installed: String, linksToThisApp: Bool)
    /// It runs and reports the same known build as this app.
    case current(installed: String)

    static let searchPaths = ["/usr/local/bin/keykeeper", "/opt/homebrew/bin/keykeeper"]

    /// 【曾经的 bug】"keykeeper unknown" on either side used to count as current, so a build
    /// without version information showed a green check next to "Installed: keykeeper unknown".
    /// 【验收 R3】a link to this app's CLI also used to turn unknown green; it no longer does.
    static func derive(installedVersion: String?, appVersion: String, linksToThisApp: Bool = false) -> CLIInstallState {
        guard let installedVersion, !installedVersion.isEmpty else { return .missing }
        guard isKnown(installedVersion), isKnown(appVersion) else {
            return .unverified(installed: installedVersion, linksToThisApp: linksToThisApp)
        }
        return installedVersion == appVersion ? .current(installed: installedVersion) : .stale(installed: installedVersion)
    }

    static func isKnown(_ version: String) -> Bool {
        let revision = version.split(separator: " ").last.map(String.init) ?? version
        return !revision.isEmpty && revision != "unknown"
    }

    var isUsable: Bool {
        switch self {
        case .missing, .failed: return false
        case .stale, .unverified, .current: return true
        }
    }

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    /// A test build (isolated Keychain) leaves the installed command-line tool alone.
    ///
    /// 【曾经的 bug】2026-11-08 主力 Mac 验收截图：测试版的欢迎页写「CLI is out of date」并给「Update」。
    /// 那只是因为正式 App 和测试版是两个版本；点了会把系统里的 keykeeper 链接改指向测试版，测试版目录
    /// 一清理，命令行工具就坏了。
    nonisolated(unsafe) static var leavesInstalledToolAlone = TestInstance.isIsolated

    /// Worth a notice on the home screen: something one install click fixes.
    var needsAttention: Bool {
        if Self.leavesInstalledToolAlone { return false }
        switch self {
        case .missing, .failed, .stale: return true
        case .unverified, .current: return false
        }
    }

    /// The CLI inside this app bundle, which an install links to.
    static var bundledCLIPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/keykeeper").path
    }

    /// Runs `<path> --version` for the first binary found on the search paths, bounded in time.
    static func probe(appVersion: String, paths: [String] = searchPaths,
                      bundledCLI: String = bundledCLIPath, timeout: TimeInterval = 3) -> CLIInstallState {
        // The entry itself, not its target: a link left behind by a moved app still "exists".
        guard let path = paths.first(where: { (try? FileManager.default.attributesOfItem(atPath: $0)) != nil }) else {
            return .missing
        }
        guard FileManager.default.isExecutableFile(atPath: path) else { return .failed(path: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failed(path: path)
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return .failed(path: path)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, let version, !version.isEmpty, version.count <= 128 else {
            return .failed(path: path)
        }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let bundled = URL(fileURLWithPath: bundledCLI).resolvingSymlinksInPath().path
        return derive(installedVersion: version, appVersion: appVersion, linksToThisApp: resolved == bundled)
    }

    /// An older standalone Claude Code skill. Its presence proves nothing about the plugin; it is
    /// only used to warn that two copies of the KeyKeeper instructions could both be active.
    static func legacyStandaloneSkillExists(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let candidates = [
            home.appendingPathComponent(".claude/skills/keykeeper/SKILL.md"),
            home.appendingPathComponent(".claude/skills/keykeeper.md"),
        ]
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Shared by the welcome screen, the home notice and Settings, so all three say the same thing.
extension CLIInstallState {
    var title: String {
        switch self {
        case .missing: return L("CLI not installed")
        case .failed: return L("The keykeeper command doesn’t run")
        case .stale: return L("CLI is out of date")
        case .unverified: return L("CLI version not confirmed")
        case .current: return L("CLI runs and matches this app")
        }
    }

    var detail: String {
        if Self.leavesInstalledToolAlone, !isCurrent {
            return L("This is a test build. The keykeeper command keeps pointing at the installed KeyKeeper and is not changed from here.")
        }
        switch self {
        case .missing:
            return L("Agents and scripts use the keykeeper command to reach KeyKeeper.")
        case .failed(let path):
            return L("Found at \(path), but it did not answer. Installing again points it at this app.")
        case .stale(let installed):
            return L("The installed CLI (\(installed)) was built from a different version than this app (\(BuildVersion.identifier)). Update it so the two agree.")
        case .unverified(let installed, let linksToThisApp):
            return linksToThisApp
                ? L("It runs and points to this app’s own CLI, but its version could not be confirmed (\(installed)).")
                : L("It runs, but its version could not be confirmed (\(installed)). Installing again points it at this app.")
        case .current(let installed):
            return installed
        }
    }

    var actionLabel: String? {
        if Self.leavesInstalledToolAlone { return nil }
        switch self {
        case .missing: return L("Install")
        case .failed: return L("Reinstall")
        // Reinstalling cannot confirm a version when the link already points here.
        case .unverified(_, let linksToThisApp): return linksToThisApp ? nil : L("Reinstall")
        case .stale: return L("Update")
        case .current: return nil
        }
    }
}
