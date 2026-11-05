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
                        AgentHostSteps(host: host, setup: setup)
                            .padding(.vertical, DS.Spacing.sm)
                    }
                    .font(.callout)
                    .accessibilityIdentifier("agent-plugin-\(host.rawValue)")
                }
            } else {
                AgentHostSteps(host: .codex, setup: setup)
            }
        }
        .dsCard(padding: DS.Spacing.md)
    }
}
