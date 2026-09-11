import SwiftUI
import KeyKeeperCore

/// Global switches that used to be scattered over the list footer and the setup screen.
struct SettingsView: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @ObservedObject var updateController: UpdateController
    var onBack: () -> Void
    var onShowServiceGrants: () -> Void
    var onShowSetup: () -> Void

    @State private var enforceServiceGrants = false
    @State private var serviceModeError: String?
    @State private var serviceGrantCount = 0
    @State private var launchAtLogin = false
    @State private var launchAtLoginError: String?
    @State private var cliState: CLIInstallState = .missing
    @State private var cliError: String?

    private let serviceGrantStore = ServiceGrantStore.default

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text(L("Back"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
            }
            .padding()

            Text(L("Settings"))
                .font(.title3.weight(.semibold))
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.sm)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    languageCard
                    backgroundAccessCard
                    startupCard
                    updatesCard
                    cliCard
                    dataCard
                    Text("KeyKeeper \(BuildVersion.identifier)")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.6))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal)
                .padding(.bottom, DS.Spacing.md)
            }
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        .onAppear(perform: load)
    }

    // MARK: - Cards

    private var languageCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Language"))
            Picker(L("Language"), selection: $interfaceLanguage) {
                Text(L("Follow system")).tag("system")
                Text("简体中文").tag("zh-Hans")
                Text("English").tag("en")
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var backgroundAccessCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Background access"))
            Toggle(isOn: $enforceServiceGrants) {
                Text(L("Ask me before a new script or agent uses a \"Background OK\" key"))
                    .font(.callout)
            }
            .onChange(of: enforceServiceGrants) { _, value in save(value) }
            Text(enforceServiceGrants
                 ? L("Each new caller (a cron job, an IDE, an agent) is shown once in an approval window. Approved callers keep working unattended.")
                 : L("Any process on this Mac can read \"Background OK\" keys without asking. Turn this on before running untrusted tools."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onShowServiceGrants()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield").font(.caption)
                    Text(serviceGrantCount == 1 ? L("1 approved caller") : L("\(serviceGrantCount) approved callers"))
                        .font(.caption)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            if let serviceModeError {
                Text(serviceModeError).font(.caption2).foregroundColor(.red)
            }
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var startupCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Startup"))
            Toggle(isOn: $launchAtLogin) {
                Text(L("Launch KeyKeeper at login"))
                    .font(.callout)
            }
            .disabled(!LoginItemManager.isAvailable)
            .onChange(of: launchAtLogin) { _, value in
                guard value != LoginItemManager.isEnabled else { return }
                do {
                    try LoginItemManager.setEnabled(value)
                    launchAtLoginError = nil
                } catch {
                    launchAtLoginError = error.localizedDescription
                    launchAtLogin = LoginItemManager.isEnabled
                }
            }
            Text(LoginItemManager.isAvailable
                 ? L("After a restart the vault is locked until you unlock it, but the app is ready in the menu bar.")
                 : L("Available when KeyKeeper runs from the .app in Applications."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.caption2).foregroundColor(.red)
            }
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var cliCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Command line"))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cliTitle).font(.callout)
                    Text(cliDetail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let action = cliActionLabel {
                    Button(action) {
                        cliError = CLIInstaller.installWithAdminPrivileges()
                        cliState = CLIInstallState.probe(appVersion: BuildVersion.identifier)
                    }
                    .font(.caption)
                }
            }
            if let cliError {
                Text(cliError).font(.caption2).foregroundColor(.red)
            }
            Button(L("Show setup again")) { onShowSetup() }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var updatesCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Updates"))
            Toggle(isOn: Binding(
                get: { updateController.automaticallyInstallsUpdates },
                set: { updateController.setAutomaticallyInstallsUpdates($0) }
            )) {
                Text(L("Install updates automatically"))
                    .font(.callout)
            }
            .disabled(!updateController.isAvailable)

            Text(updateDescription)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L("Check for Updates…")) {
                updateController.checkForUpdates()
            }
            .font(.caption)
            .disabled(!updateController.canCheckForUpdates)
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var dataCard: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Data"))
            Text(L("Key values live in the macOS Keychain (covered by your normal macOS backup). This folder holds names, notes and approvals — no secret values."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(L("Show data folder in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([KeyKeeperPaths.applicationSupportDirectory])
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundColor(.accentColor)
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var cliTitle: String {
        switch cliState {
        case .missing: return L("CLI not installed")
        case .stale: return L("CLI is out of date")
        case .current: return L("CLI up to date")
        }
    }

    private var updateDescription: String {
        guard updateController.isAvailable else {
            return L("Updates are unavailable in this development build.")
        }
        return updateController.automaticallyInstallsUpdates
            ? L("KeyKeeper checks daily and installs signed updates in the background.")
            : L("KeyKeeper checks daily and tells you when a signed update is available.")
    }

    private var cliDetail: String {
        switch cliState {
        case .missing: return L("Scripts and AI tools need `keykeeper` on the PATH.")
        case .stale(let installed): return L("\(installed) vs app \(BuildVersion.identifier)")
        case .current(let installed): return installed
        }
    }

    private var cliActionLabel: String? {
        switch cliState {
        case .missing: return L("Install")
        case .stale: return L("Update")
        case .current: return nil
        }
    }

    // MARK: - Data

    private func load() {
        do {
            enforceServiceGrants = try serviceGrantStore.authorizationMode() == .enforced
            serviceGrantCount = try serviceGrantStore.grants().count
            serviceModeError = nil
        } catch {
            serviceModeError = error.localizedDescription
        }
        launchAtLogin = LoginItemManager.isEnabled
        cliState = CLIInstallState.probe(appVersion: BuildVersion.identifier)
        updateController.refresh()
    }

    private func save(_ enforced: Bool) {
        do {
            try serviceGrantStore.setAuthorizationMode(enforced ? .enforced : .permissive)
            serviceModeError = nil
        } catch {
            serviceModeError = error.localizedDescription
        }
    }
}
