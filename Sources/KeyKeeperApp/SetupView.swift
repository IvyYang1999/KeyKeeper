import SwiftUI

/// First-run guide in the menu bar popover: this Mac → first key → optional agent → first use.
///
/// 2026-11-05 rework. The old screen taught one host (Claude Code) through a raw GitHub skill
/// prompt, turned green when a file existed, and put its main button below a long scroll so the
/// button showed half cut off. Now the header and the action bar stay fixed, only the middle
/// scrolls, agent setup reuses the bundled Codex / Claude Code plugin, and nothing is shown as
/// working unless it was actually checked.
struct SetupView: View {
    @Binding var setupComplete: Bool
    /// nil while the list has not loaded or failed to load: unknown, not "empty".
    var keyCount: Int?
    var onAddKey: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onOpenAccess: () -> Void = {}
    var plugins: AgentPluginSetup = .production()
    /// Probing runs a process; snapshots pass a fixed state instead.
    var probeCLI: () -> CLIInstallState = { CLIInstallState.probe(appVersion: BuildVersion.identifier) }
    /// Snapshots render the whole guide unclipped; the app always scrolls inside the popover.
    var scrolls = true

    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @State private var cliState: CLIInstallState = .missing
    @State private var hosts: Set<AgentPluginSetup.Host> = []
    @State private var showImport = false
    @State private var isInstallingCLI = false
    @State private var errorMessage: String?
    @State private var legacySkill = false

    init(setupComplete: Binding<Bool>, keyCount: Int?, onAddKey: @escaping () -> Void = {},
         onOpenSettings: @escaping () -> Void = {}, onOpenAccess: @escaping () -> Void = {},
         plugins: AgentPluginSetup = .production(),
         probeCLI: @escaping () -> CLIInstallState = { CLIInstallState.probe(appVersion: BuildVersion.identifier) },
         scrolls: Bool = true, initialHosts: Set<AgentPluginSetup.Host> = [], initialShowImport: Bool = false) {
        _setupComplete = setupComplete
        self.keyCount = keyCount; self.onAddKey = onAddKey; self.onOpenSettings = onOpenSettings
        self.onOpenAccess = onOpenAccess; self.plugins = plugins; self.probeCLI = probeCLI; self.scrolls = scrolls
        _hosts = State(initialValue: initialHosts)
        _showImport = State(initialValue: initialShowImport)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
            Divider()
            if scrolls {
                ScrollView { guide }
            } else {
                guide
            }
            Divider()
            footer
                .padding(.horizontal, DS.Spacing.lg)
                .padding(.vertical, DS.Spacing.md)
        }
        .frame(width: DS.Popover.width, height: scrolls ? DS.Popover.height : nil)
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
        .onAppear(perform: refresh)
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            thisMac
            firstKey
            agentSection
        }
        .padding(DS.Spacing.lg)
    }

    // MARK: - Fixed parts

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: "key.fill")
                .font(.system(size: 22))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Welcome to KeyKeeper")).font(.headline)
                Text(L("Keep API keys on this Mac. AI tools can use them without seeing the values."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Spacing.sm)
            LanguageMenu(selection: $interfaceLanguage)
        }
    }

    /// Names the settings group and row by their own titles, so a move in Settings moves it too.
    static var reopenHint: String { L("Reopen this guide any time in Settings → \(L("General")) → \(L("Welcome guide")).") }

    /// One exit, always visible. Skipping and finishing are the same thing: nothing here is required.
    private var footer: some View {
        HStack(spacing: DS.Spacing.sm) {
            Text(Self.reopenHint)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Spacing.sm)
            Button(L("Get Started")) { finishSetup() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - 1 · This Mac

    private var thisMac: some View {
        section(number: 1, title: L("This Mac")) {
            HStack(alignment: .top, spacing: DS.Spacing.sm) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Protected storage on this Mac is ready.")).font(.callout)
                    Text(keyCountText).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var keyCountText: String {
        switch keyCount {
        case nil: return L("The key list has not loaded yet.")
        case 0: return L("No keys here yet. Add one, or sync from your other Mac.")
        case 1: return L("1 key saved.")
        case let count?: return L("\(count) keys saved.")
        }
    }

    // MARK: - 2 · First key

    private var firstKey: some View {
        section(number: 2, title: L("Save your first key")) {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                choice(symbol: "plus.circle", title: L("Add a key"),
                       detail: L("Pick a service from the templates, or fill it in yourself."), action: onAddKey)
                choice(symbol: "square.and.arrow.down", title: L("Import keys you already have"),
                       detail: L("From a project’s .env file or a service-account JSON file."),
                       expanded: showImport) { withAnimation { showImport.toggle() } }
                if showImport { importDetails }
                choice(symbol: "icloud", title: L("Sync from your other Mac"),
                       detail: L("Uses your iCloud account. Turn on iCloud sync in Settings on both Macs."),
                       action: onOpenSettings)
            }
        }
    }

    private var importDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(L(".env file: in the project folder, run this yourself or ask your agent to. KeyKeeper lists the variable names on this Mac for you to confirm. The file itself is not changed."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            CopyableCommand("keykeeper import ./.env")
            Text(L("Service-account JSON file: choose Add a key, then import the file there."))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if !cliState.isUsable {
                Text(L("The import command needs the command-line tool from step 3."))
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.md)
        .surface(.inset, radius: DS.Radius.sm)
    }

    // MARK: - 3 · Agent (optional)

    private var agentSection: some View {
        section(number: 3, title: L("Connect an AI tool"), badge: L("Optional")) {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                Text(L("After you install the plugin, your agent knows how to ask KeyKeeper for a key. You still approve its use on this Mac. Using only the app? Skip this."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                cliRow
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    Text(L("Which tools do you use?")).font(.caption.weight(.semibold))
                    HStack(spacing: DS.Spacing.sm) {
                        ForEach(AgentPluginSetup.Host.allCases) { host in
                            hostToggle(host)
                        }
                    }
                }
                ForEach(AgentPluginSetup.Host.allCases.filter(hosts.contains)) { host in
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text(host.title).font(.callout.weight(.semibold))
                        AgentHostSteps(host: host, setup: plugins)
                        if host == .claude && legacySkill {
                            Text(L("An older standalone KeyKeeper skill is in ~/.claude/skills. After installing the plugin, remove the old one so two versions are not active at once."))
                                .font(.caption2).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(DS.Spacing.md)
                    .surface(.inset, radius: DS.Radius.sm)
                }
                Button(L("Open usage permissions")) { onOpenAccess() }
                    .buttonStyle(.plain).font(.caption).foregroundColor(.accentColor)
                    .help(L("See and revoke what you approved."))
            }
        }
    }

    private var cliRow: some View {
        HStack(alignment: .top, spacing: DS.Spacing.sm) {
            Image(systemName: cliState.isCurrent ? "checkmark.circle.fill" : (cliState.isUsable ? "questionmark.circle" : "terminal"))
                .foregroundColor(cliState.isCurrent ? .green : (cliState.needsAttention ? .orange : .secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(cliState.title).font(.callout)
                Text(cliState.isCurrent ? L("Agents use this command to reach KeyKeeper.") : cliState.detail)
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundColor(.red)
                }
            }
            Spacer(minLength: DS.Spacing.sm)
            if let label = cliState.actionLabel {
                Button(action: installCLI) {
                    if isInstallingCLI { ProgressView().controlSize(.small) } else { Text(label) }
                }
                .disabled(isInstallingCLI)
                .controlSize(.small)
            }
        }
    }

    private func hostToggle(_ host: AgentPluginSetup.Host) -> some View {
        let selected = hosts.contains(host)
        return Button {
            withAnimation { if selected { hosts.remove(host) } else { hosts.insert(host) } }
        } label: {
            Label(host.title, systemImage: selected ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : nil)
        .controlSize(.small)
        .accessibilityIdentifier("setup-host-\(host.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Building blocks

    private func section<Content: View>(number: Int, title: String, badge: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.xs) {
                Text("\(number)")
                    .font(.caption2.bold()).foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                Text(title).font(.callout.bold())
                if let badge {
                    Text(badge).font(.caption2).foregroundColor(.secondary)
                }
            }
            content()
        }
    }

    private func choice(symbol: String, title: String, detail: String, expanded: Bool? = nil,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: symbol).font(.system(size: 16)).foregroundColor(.accentColor).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout).foregroundColor(.primary)
                    Text(detail).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: expanded == nil ? "chevron.right" : (expanded! ? "chevron.up" : "chevron.down"))
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(DS.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .surface(.card)
    }

    // MARK: - Actions

    private func refresh() {
        cliState = probeCLI()
        legacySkill = CLIInstallState.legacyStandaloneSkillExists()
    }

    private func finishSetup() {
        setupComplete = true
        UserDefaults.standard.set(true, forKey: "setupComplete")
    }

    private func installCLI() {
        isInstallingCLI = true
        errorMessage = CLIInstaller.installWithAdminPrivileges().map { AppL10n.text($0) }
        cliState = probeCLI()
        isInstallingCLI = false
    }
}

/// What to do → where → what you will see, for one host. Shared with Settings so the guide and
/// the settings card can never teach two different procedures.
struct AgentHostSteps: View {
    let host: AgentPluginSetup.Host
    var setup: AgentPluginSetup = .production()

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            if setup.isAvailable, let command = setup.commands(for: host) {
                step(1, L("In Terminal, run this to install the KeyKeeper plugin:"))
                CopyableCommand(command)
                step(2, L("Start a new conversation in \(host.title) and ask for what you need, for example: “Use my OpenAI key from KeyKeeper to run the tests. Don’t show its value.”"))
                step(3, L("The first time, this Mac shows an approval window: who is asking, which key, and for how long. Nothing is used until you approve."))
                Text(L("KeyKeeper cannot check whether the plugin is installed. When the first approval window appears, the connection works."))
                    .font(.caption2).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                if host == .codex, let url = setup.codexURL {
                    Link(L("View plugin in Codex"), destination: url).font(.caption)
                } else if host == .claude {
                    Link(L("Claude Code plugin guide"), destination: URL(string: "https://code.claude.com/docs/en/plugins")!)
                        .font(.caption)
                }
            } else {
                Text(L("This build does not include the plugin package. Install a packaged KeyKeeper update to get it."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            Text("\(number).").font(.caption.monospacedDigit()).foregroundColor(.secondary)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Subviews

struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    init(_ command: String) {
        self.command = command
    }

    var body: some View {
        HStack(alignment: .top) {
            Text(command)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            }) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundColor(copied ? .green : .accentColor)
            }
            .buttonStyle(.plain)
            .help(L("Copy"))
        }
        .padding(8)
        .surface(.inset, radius: DS.Radius.sm)
    }
}
