import SwiftUI

struct AgentPluginsCard: View {
    var setup: AgentPluginSetup = .production()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("AI tool integration"))
            Text(L("Teach your AI tool to use KeyKeeper. Installing a plugin does not grant access to any key."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if setup.isAvailable {
                ForEach(AgentPluginSetup.Host.allCases) { host in
                    DisclosureGroup(host.title) {
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text(L("Run this in Terminal, then start a new conversation:"))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let command = setup.commands(for: host) {
                                CopyableCommand(command)
                            }
                            Text(L("Then tell it: check KeyKeeper and use my API key without showing its value."))
                                .font(.caption2)
                                .fixedSize(horizontal: false, vertical: true)
                            if host == .codex, let url = setup.codexURL {
                                Link(L("View plugin in Codex"), destination: url).font(.caption)
                            } else {
                                Link(L("Claude Code plugin guide"), destination: URL(string: "https://code.claude.com/docs/en/plugins")!)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, DS.Spacing.sm)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("agent-plugin-\(host.rawValue)")
                }
            } else {
                Text(L("This build does not include the plugin package. Install a packaged KeyKeeper update to get it."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .dsCard(padding: DS.Spacing.md)
    }
}
