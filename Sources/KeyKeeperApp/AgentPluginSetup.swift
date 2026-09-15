import Foundation

/// Install instructions only: no process execution, host configuration writes or secret access.
struct AgentPluginSetup {
    enum Host: String, CaseIterable, Identifiable {
        case codex, claude
        var id: String { rawValue }
        var title: String { self == .codex ? "Codex" : "Claude Code" }
    }

    let root: URL?
    static let requiredFiles = [
        ".agents/plugins/marketplace.json", ".claude-plugin/marketplace.json",
        "Plugins/keykeeper/.codex-plugin/plugin.json", "Plugins/keykeeper/.claude-plugin/plugin.json",
        "Plugins/keykeeper/skills/keykeeper/SKILL.md",
        "Plugins/keykeeper/skills/keykeeper/references/safe-import.md"
    ]

    static func production(bundle: Bundle = .main) -> Self {
        Self(root: bundle.resourceURL?.appendingPathComponent("AgentPlugins"))
    }

    var isAvailable: Bool {
        guard let root else { return false }
        return Self.requiredFiles.allSatisfy {
            (try? root.appendingPathComponent($0).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    func commands(for host: Host) -> String? {
        guard isAvailable, let root else { return nil }
        let quoted = "'" + root.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let executable = host == .codex ? "codex" : "claude"
        let verb = host == .codex ? "add" : "install"
        return "\(executable) plugin marketplace add \(quoted) && \(executable) plugin \(verb) keykeeper@keykeeper-plugins"
    }

    var codexURL: URL? {
        guard isAvailable, let root else { return nil }
        var url = URLComponents()
        url.scheme = "codex"
        url.host = "plugins"
        url.path = "/keykeeper"
        url.queryItems = [.init(name: "marketplacePath", value: root.appendingPathComponent(".agents/plugins/marketplace.json").path)]
        return url.url
    }
}
