import SwiftUI

/// Rows of the Developer group: one line saying what the plugins do, then one row per AI tool
/// that opens to the same steps the welcome guide shows.
struct AgentPluginsRows: View {
    var setup: AgentPluginSetup = .production()

    var body: some View {
        SettingsRow(title: L("AI tool integration"),
                    detail: L("Teach your AI tool to use KeyKeeper. Installing a plugin does not grant access to any key."))
        if setup.isAvailable {
            ForEach(AgentPluginSetup.Host.allCases) { host in
                SettingsDivider()
                DisclosureGroup {
                    AgentHostSteps(host: host, setup: setup)
                        .padding(.vertical, DS.Spacing.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(host.title)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .accessibilityIdentifier("agent-plugin-\(host.rawValue)")
            }
        } else {
            AgentHostSteps(host: .codex, setup: setup)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
        }
    }
}
