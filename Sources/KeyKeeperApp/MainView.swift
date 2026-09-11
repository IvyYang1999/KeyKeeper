import SwiftUI
import KeyKeeperCore

/// The menu bar popover: the "right now" half of KeyKeeper.
///
/// It holds what comes to you — requests waiting for a yes or no — and what you are about
/// to do with a key in hand: store it, then hand its name to your agent. Browsing, editing,
/// approvals history, website sessions and settings live in the main window. The rule that
/// decides where something goes: did someone come to me, or am I going to do something?
struct MainView: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @AppStorage("setupComplete") private var setupComplete = false
    @StateObject private var viewModel: CredentialListViewModel
    @StateObject private var addVM: AddCredentialViewModel
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var inbox = UICommandInbox.shared
    @State private var showingAdd = false
    @State private var copiedPromptId: String?
    @State private var clipboardNotice: String?

    private let session: any CredentialSessionManaging
    private var importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?
    private var openMainWindow: (MainWindowRouter.Section?, String?) -> Void
    private var reopenPopover: () -> Void

    init(session: any CredentialSessionManaging,
         importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)? = nil,
         openMainWindow: @escaping (MainWindowRouter.Section?, String?) -> Void = { _, _ in },
         reopenPopover: @escaping () -> Void = {}) {
        self.session = session
        self.importFile = importFile
        self.openMainWindow = openMainWindow
        self.reopenPopover = reopenPopover
        _viewModel = StateObject(wrappedValue: CredentialListViewModel(session: session))
        _addVM = StateObject(wrappedValue: AddCredentialViewModel(session: session))
    }

    var body: some View {
        Group {
            if !setupComplete {
                SetupView(setupComplete: $setupComplete)
            } else if showingAdd {
                AddCredentialView(
                    vm: addVM,
                    onSave: {
                        viewModel.load()
                        addVM.reset()
                        showingAdd = false
                        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    },
                    onCancel: { showingAdd = false },
                    onOpenExisting: { id in
                        addVM.reset()
                        showingAdd = false
                        openMainWindow(.keys, id)
                    },
                    onImportFile: importFile
                )
                .background(GlassSurface(intensity: 0.7))
            } else {
                home
            }
        }
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
        // Handled on the outer body so a link that arrived before the popover was ever
        // rendered is still picked up on first render.
        .onReceive(inbox.$pendingAddCredential.compactMap { $0 }) { link in
            if case .addCredential(let label, let fields, let notes) = link {
                addVM.prefill(label: label, fields: fields, notes: notes)
                showingAdd = true
            }
            DispatchQueue.main.async { inbox.clearAddCredential() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardCredentialSaved)) { _ in viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in viewModel.load() }
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("KeyKeeper").font(.title3.weight(.semibold))
                Spacer()
                Button(L("Open KeyKeeper")) { openMainWindow(nil, nil) }
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 16) {
                if !approvals.items.isEmpty {
                    waitingSection
                }
                saveSection
                recentSection
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)

            footer
        }
        .frame(width: DS.Popover.width)
        .fixedSize(horizontal: false, vertical: true)
        .background(GlassSurface(intensity: 0.7))
        .onAppear {
            viewModel.load()
            addVM.refreshExistingIds()
        }
    }

    // MARK: Waiting for you

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionTitle(text: L("Waiting for you"), trailing: "\(approvals.items.count)")
            ForEach(approvals.items.prefix(3)) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbol)
                            .foregroundColor(.accentColor)
                            .frame(width: 26, height: 26)
                            .surface(.raised, radius: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Text(item.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                        }
                    }
                    HStack(spacing: 8) {
                        if let expiresAt = item.expiresAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                let seconds = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
                                Text(L("Cancels in \(seconds) s")).font(.caption2).foregroundColor(.secondary).monospacedDigit()
                            }
                        }
                        Spacer()
                        Button(L("Deny"), action: item.deny)
                            .controlSize(.small)
                        Button(action: item.confirm) {
                            Text(item.opensWindow ? "\(item.confirmTitle)…" : item.confirmTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(item.destructive ? .red : .accentColor)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .surface(.attention)
            }
        }
    }

    // MARK: Save a key

    private var saveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionTitle(text: L("Save a key"))
            HStack(spacing: 8) {
                saveTile(L("From clipboard"), symbol: "doc.on.clipboard", highlighted: true) { saveFromClipboard() }
                saveTile(L("From file"), symbol: "doc.badge.gearshape") { saveFromFile() }
                    .disabled(importFile == nil)
                saveTile(L("Type it in"), symbol: "pencil") {
                    if !addVM.hasDraft { addVM.reset() }
                    showingAdd = true
                }
            }
            Text(clipboardNotice ?? L("The clipboard is read only when you click, and cleared after saving."))
                .font(.caption2)
                .foregroundColor(clipboardNotice == nil ? .secondary : .orange)
                .fixedSize(horizontal: false, vertical: true)
            if addVM.hasDraft {
                Button {
                    showingAdd = true
                } label: {
                    Label(L("Draft: \(addVM.draftTitle)"), systemImage: "doc.badge.ellipsis")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            }
        }
    }

    private func saveTile(_ title: String, symbol: String, highlighted: Bool = false,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 19)).foregroundColor(.accentColor)
                Text(title).font(.caption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .glassCard(radius: DS.Radius.md, selected: highlighted)
        }
        .buttonStyle(.plain)
    }

    private func saveFromClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            clipboardNotice = L("There is no text on the clipboard. Copy the key first.")
            return
        }
        clipboardNotice = nil
        addVM.prefillFromClipboard(text.trimmingCharacters(in: .whitespacesAndNewlines),
                                   changeCount: pasteboard.changeCount)
        showingAdd = true
    }

    private func saveFromFile() {
        AddCredentialView.pickServiceAccountFile { url in
            addVM.reset()
            addVM.useFile(url)
            showingAdd = true
            // The open panel takes focus, which closes a non-detached popover.
            reopenPopover()
        }
    }

    // MARK: Just saved

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassSectionTitle(text: L("Just saved"))
            let recent = RecentCredentials.newest(viewModel.credentials)
            if recent.isEmpty {
                Text(L("Once a key is saved, you get a paragraph here to paste straight to your agent."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { index, item in
                        recentRow(item.id, item.credential)
                        if index < recent.count - 1 {
                            GlassSeparator()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .glassCard()
                Text(L("Paste the prompt into your agent. It gets the key's name, never its value."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func recentRow(_ id: String, _ credential: Credential) -> some View {
        HStack(spacing: 8) {
            Button { openMainWindow(.keys, id) } label: {
                HStack(spacing: 6) {
                    Text(credential.label).font(.callout).lineLimit(1)
                    // The ID only adds information when it differs from the name.
                    Text(credential.label.caseInsensitiveCompare(id) == .orderedSame
                         ? credential.fields.keys.sorted().joined(separator: " · ")
                         : id)
                        .font(.caption.monospaced()).foregroundColor(.secondary).lineLimit(1)
                    Text("· \(RecentCredentials.dayLabel(for: credential.created))")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Open in KeyKeeper"))

            Button {
                PlainPasteboard.copy(AgentPromptCopy.prompt(credentialId: id, credential: credential))
                copiedPromptId = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if copiedPromptId == id { copiedPromptId = nil }
                }
            } label: {
                Text(copiedPromptId == id ? L("Copied") : L("Copy prompt"))
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.plain)
            .foregroundColor(copiedPromptId == id ? .green : .accentColor)
            .help(L("Copy prompt for your agent"))
        }
        .padding(.vertical, 9)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button(L("\(viewModel.credentials.count) keys in total")) { openMainWindow(.keys, nil) }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            Spacer()
            Button { openMainWindow(.settings, nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("Settings"))
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("KeyKeeper starts again automatically the next time a key is requested."))
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { GlassSeparator() }
    }
}

enum CredentialDeletionCopy {
    static let template = "Its key values are removed from the macOS Keychain. This can't be undone, and anything running `keykeeper run -c {0}` will stop working."

    static func message(credentialId: String) -> String {
        AppL10n.render(template, arguments: [credentialId], language: AppL10n.language)
    }
}
