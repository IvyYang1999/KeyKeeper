import SwiftUI
import KeyKeeperCore

/// What Settings reads and changes. Production by default; synthetic in tests and renders, so a
/// render never touches the real Keychain, approvals, login items, CLI or iCloud.
@MainActor
struct SettingsServices {
    var approvals: ApprovalStore
    var reviewer: ReviewerService
    var loginItemAvailable: () -> Bool
    var loginItemEnabled: () -> Bool
    var setLoginItem: (Bool) throws -> Void
    var probeCLI: () -> CLIInstallState
    /// Returns an error message, or nil when it worked.
    var installCLI: () -> String?
    var showDataFolder: () -> Void
    var agentPlugins: AgentPluginSetup

    static var production: SettingsServices {
        SettingsServices(
            approvals: .shared,
            reviewer: .shared,
            loginItemAvailable: { LoginItemManager.isAvailable },
            loginItemEnabled: { LoginItemManager.isEnabled },
            setLoginItem: { try LoginItemManager.setEnabled($0) },
            probeCLI: { CLIInstallState.probe(appVersion: BuildVersion.identifier) },
            installCLI: { CLIInstaller.installWithAdminPrivileges().map { AppL10n.text($0) } },
            showDataFolder: { NSWorkspace.shared.activateFileViewerSelecting([KeyKeeperPaths.applicationSupportDirectory]) },
            agentPlugins: .production()
        )
    }
}

/// Settings in the main window, connected to the real services.
struct SettingsView: View {
    @ObservedObject var updateController: UpdateController
    @ObservedObject private var cloudSync = ICloudSyncRuntime.shared
    var onShowServiceGrants: () -> Void
    var onShowSetup: () -> Void

    var body: some View {
        LanguageScoped(content: SettingsPage(
            updateController: updateController,
            cloudState: cloudSync.state,
            cloudAction: cloudSync.perform,
            services: .production,
            onShowServiceGrants: onShowServiceGrants,
            onShowSetup: onShowSetup
        ))
    }
}

/// Draws its content again from scratch when the interface language changes.
///
/// 【曾经的 bug】2026-11-08 主力 Mac 验收 follow-up：在设置页切换语言后，部分子标题还停在原来的语言。
/// `L()` reads the preference when a body runs, and a subview whose inputs did not change is
/// not run again. A new identity makes every subview run again in the new language.
struct LanguageScoped<Content: View>: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    let content: Content
    var body: some View { content.id(interfaceLanguage) }
}

/// Four groups, like System Settings: General, iCloud sync, Security and approvals, Developer.
///
/// 【曾经的 bug】2026-11-07 yyt：「iCloud 同步部分也很糟糕，两个按钮居然是那样的排布，界面语言也是一样」。
/// It used to be ten cards in one long column, each with its own layout: a full-width language
/// menu, buttons stacked on the left, the version floating at the bottom.
struct SettingsPage: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @ObservedObject var updateController: UpdateController
    let cloudState: ICloudSyncPresentation
    let cloudAction: (ICloudSyncAction) -> Void
    let services: SettingsServices
    var onShowServiceGrants: () -> Void
    var onShowSetup: () -> Void

    @State private var enforceServiceGrants = false
    @State private var serviceModeError: String?
    @State private var serviceGrantCount = 0
    @State private var reviewerEnabled = false
    @State private var reviewerKeyDraft = ""
    @State private var reviewerHasKey = false
    @State private var reviewerBaseURL = ""
    @State private var reviewerAPI = "auto"
    @State private var reviewerModel = ""
    @State private var reviewerModels: [String] = []
    @State private var reviewerListing = false
    @State private var reviewerStatus: String?
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var cliState: CLIInstallState = .missing
    @State private var cliError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Settings"))
                .font(.system(size: 22, weight: .bold))
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    generalGroup
                    ICloudSyncSettingsCard(state: cloudState, action: cloudAction)
                    securityGroup
                    developerGroup
                }
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.xl)
            }
        }
        .panelFrame()
        .onAppear(perform: load)
    }

    // MARK: - General

    private var generalGroup: some View {
        SettingsGroup(title: L("General")) {
            SettingsRow(title: L("Language")) {
                Picker(L("Language"), selection: $interfaceLanguage) {
                    Text(L("Follow system")).tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            SettingsDivider()
            SettingsRow(title: L("Launch KeyKeeper at login"),
                        detail: launchAtLoginError ?? (services.loginItemAvailable()
                            ? AppL10n.text(SettingsCopy.launchAtLoginDetail)
                            : L("Available when KeyKeeper runs from the .app in Applications.")),
                        detailColor: launchAtLoginError == nil ? .secondary : .red) {
                SettingsSwitch(label: L("Launch KeyKeeper at login"), isOn: $launchAtLogin)
                    .disabled(!services.loginItemAvailable())
                    .onChange(of: launchAtLogin) { _, value in setLaunchAtLogin(value) }
            }
            SettingsDivider()
            UpdatesSettingsRows(updateController: updateController)
            SettingsDivider()
            SettingsRow(title: L("Welcome guide"),
                        detail: L("Adding your first key, importing, and connecting an AI tool.")) {
                Button(L("Show again")) { onShowSetup() }
            }
        }
    }

    private func setLaunchAtLogin(_ value: Bool) {
        guard value != services.loginItemEnabled() else { return }
        do {
            try services.setLoginItem(value)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = services.loginItemEnabled()
        }
    }

    // MARK: - Security and approvals

    private var securityGroup: some View {
        SettingsGroup(title: L("Security and approvals")) {
            SettingsRow(title: L("Ask me before a new script or agent uses a \"Background OK\" key"),
                        detail: serviceModeError ?? (enforceServiceGrants
                            ? L("Each new caller (a cron job, an IDE, an agent) is shown once in an approval window. Approved callers keep working unattended.")
                            : L("Any process on this Mac can read \"Background OK\" keys without asking. Turn this on before running untrusted tools.")),
                        detailColor: serviceModeError == nil ? .secondary : .red) {
                SettingsSwitch(label: L("Ask me before a new script or agent uses a \"Background OK\" key"),
                               isOn: $enforceServiceGrants)
                    .onChange(of: enforceServiceGrants) { _, value in save(value) }
            }
            SettingsDivider()
            Button(action: onShowServiceGrants) {
                SettingsRow(title: L("Approved callers")) {
                    HStack(spacing: 6) {
                        Text("\(serviceGrantCount)").foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            SettingsDivider()
            ApprovalRemindersRow()
            SettingsDivider()
            reviewerRows
        }
    }

    /// yyt 2026-09-14: 「应该有一个独立的第三方，检查下模型的需求合不合理」。
    /// yyt 2026-09-14: "Base URL and API key go together; the first box looked like the key
    /// box and then I had to go store a credential." Now it reads top to bottom like every
    /// other API settings page: Base URL, API key, model — and saving the key looks up the models.
    /// The connection details show once the switch is on.
    @ViewBuilder private var reviewerRows: some View {
        SettingsRow(title: L("Independent reviewer"),
                    detail: L("Ask a second model whether each request is necessary and minimal")) {
            SettingsSwitch(label: L("Independent reviewer"), isOn: $reviewerEnabled)
                .onChange(of: reviewerEnabled) { _, value in
                    if value != services.reviewer.isEnabled { services.reviewer.isEnabled = value }
                }
        }
        if reviewerEnabled {
            VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.md, verticalSpacing: DS.Spacing.sm) {
                    GridRow {
                        fieldLabel(L("Base URL"))
                        HStack(spacing: DS.Spacing.sm) {
                            TextField(ReviewerEndpoint.defaultBaseURL, text: $reviewerBaseURL)
                                .dsInput(monospaced: true)
                                .onChange(of: reviewerBaseURL) { _, value in
                                    guard value != services.reviewer.baseURLText else { return }
                                    services.reviewer.baseURLText = value
                                    reviewerModels = []
                                }
                            Picker("", selection: $reviewerAPI) {
                                Text(L("Auto")).tag("auto")
                                Text("Anthropic").tag(ReviewerEndpoint.API.anthropic.rawValue)
                                Text(L("OpenAI-compatible")).tag(ReviewerEndpoint.API.openAICompatible.rawValue)
                            }
                            .labelsHidden()
                            .fixedSize()
                            .onChange(of: reviewerAPI) { _, value in
                                let api = ReviewerEndpoint.API(rawValue: value)
                                if api != services.reviewer.apiOverride { services.reviewer.apiOverride = api }
                            }
                        }
                    }
                    GridRow {
                        fieldLabel(L("API key"))
                        HStack(spacing: DS.Spacing.sm) {
                            SecureField(reviewerHasKey ? L("saved · paste a new one to replace") : L("paste the key here"),
                                        text: $reviewerKeyDraft)
                                .dsInput(monospaced: true)
                                .onSubmit { commitReviewerKey() }
                            Button(reviewerHasKey ? L("Replace") : L("Save")) { commitReviewerKey() }
                                .disabled(reviewerKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                            if reviewerHasKey {
                                Button(L("Forget")) {
                                    services.reviewer.apiKey = ""
                                    reviewerHasKey = false
                                    reviewerModels = []
                                    reviewerStatus = nil
                                }
                            }
                        }
                    }
                    GridRow {
                        fieldLabel(L("Model"))
                        HStack(spacing: DS.Spacing.sm) {
                            if reviewerModels.isEmpty {
                                TextField(ReviewerEndpoint.defaultModel, text: $reviewerModel)
                                    .dsInput(monospaced: true)
                                    .onChange(of: reviewerModel) { _, value in
                                        if value != services.reviewer.model { services.reviewer.model = value }
                                    }
                            } else {
                                Picker("", selection: $reviewerModel) {
                                    ForEach(reviewerModels, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .onChange(of: reviewerModel) { _, value in
                                    if value != services.reviewer.model { services.reviewer.model = value }
                                }
                            }
                            Button { findReviewerModels() } label: {
                                if reviewerListing { ProgressView().controlSize(.small) } else { Text(L("Find models")) }
                            }
                            .disabled(reviewerListing || !reviewerHasKey)
                            .help(reviewerHasKey ? L("Ask the service which models this key can use") : L("Save the key first"))
                        }
                    }
                }
                if let reviewerStatus {
                    Text(reviewerStatus).font(.caption).foregroundStyle(.secondary)
                }
                Text(L("Any service that speaks the Anthropic or OpenAI API. The key lives in KeyKeeper's own Keychain item — not in your credential list, where a program could rename things around it. The reviewer sees key names, the caller's stated reason and command, and the declared use — never a value. Its opinion is shown in the approval window; it never approves anything."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func commitReviewerKey() {
        let key = reviewerKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        services.reviewer.apiKey = key
        reviewerKeyDraft = ""
        reviewerHasKey = true
        reviewerStatus = L("Key saved. Looking up the models it can use…")
        findReviewerModels()
    }

    private func findReviewerModels() {
        reviewerListing = true
        let reviewer = services.reviewer
        Task {
            let result = await reviewer.listModels()
            reviewerListing = false
            switch result {
            case .success(let models):
                reviewerModels = models
                if !models.contains(reviewerModel) { reviewerModel = models[0]; reviewer.model = models[0] }
                reviewerStatus = L("\(models.count) models available — pick one above.")
            case .failure(let error):
                reviewerStatus = L("Could not list models: \(error.localizedDescription) You can type a model name instead.")
            }
        }
    }

    // MARK: - Developer

    private var developerGroup: some View {
        SettingsGroup(title: L("Developer")) {
            SettingsRow(title: cliState.title, detail: cliError ?? cliState.detail,
                        detailColor: cliError == nil ? .secondary : .red) {
                if let action = cliState.actionLabel {
                    Button(action) {
                        cliError = services.installCLI()
                        cliState = services.probeCLI()
                    }
                }
            }
            SettingsDivider()
            AgentPluginsRows(setup: services.agentPlugins)
            SettingsDivider()
            SettingsRow(title: L("Data folder"),
                        detail: L("Key values live in the macOS Keychain (covered by your normal macOS backup). This folder holds names, notes and approvals — no secret values.")) {
                Button(L("Show in Finder")) { services.showDataFolder() }
            }
        }
    }

    // MARK: - Data

    private func load() {
        do {
            enforceServiceGrants = try services.approvals.mode() == .enforced
            serviceGrantCount = try services.approvals.all().count
            serviceModeError = nil
        } catch {
            serviceModeError = error.localizedDescription
        }
        let reviewer = services.reviewer
        reviewerEnabled = reviewer.isEnabled
        reviewerHasKey = reviewer.hasKey
        reviewerBaseURL = reviewer.baseURLText
        reviewerAPI = reviewer.apiOverride?.rawValue ?? "auto"
        reviewerModel = reviewer.model
        launchAtLogin = services.loginItemEnabled()
        cliState = services.probeCLI()
        updateController.refresh()
    }

    /// Writes only a real change: loading the page sets the switch, and that must not write.
    private func save(_ enforced: Bool) {
        let mode: ServiceAuthorizationMode = enforced ? .enforced : .permissive
        do {
            if try services.approvals.mode() != mode { try services.approvals.setMode(mode) }
            serviceModeError = nil
        } catch {
            serviceModeError = error.localizedDescription
        }
    }
}

/// Separate from SettingsPage so the switch can be inspected with synthetic UI only.
struct ApprovalRemindersRow: View {
    @AppStorage(ApprovalAlertPreferences.soundKey) private var approvalSoundEnabled = false

    var body: some View {
        SettingsRow(title: L("Play a sound when approval is needed"),
                    detail: L("Silent by default. Pending requests stay until you decide or the requesting command stops; missed ones remain in the menu and access history.")) {
            SettingsSwitch(label: L("Play a sound when approval is needed"), isOn: $approvalSoundEnabled)
        }
    }
}

enum SettingsCopy {
    /// The Keychain unlocks with the Mac login; there is nothing for the user to unlock.
    static let launchAtLoginDetail = "Starts with your Mac, so it is in the menu bar before any script asks for a key."
}
