import SwiftUI
import KeyKeeperCore

/// The menu bar popover, modelled on the macOS 26 Passwords menu bar extra (yyt: "just copy
/// this"). It does two things: find a key and store one. The header holds + (store) and a
/// button that opens the main window; everything else lives in the main window.
///
/// Requests waiting for a yes or no still appear above the list, but only while one is
/// actually waiting.
struct MainView: View {
    enum Page: Equatable {
        case home
        case add
        case detail(String)
        /// The same editor as the main window, opened from a key's menu bar page.
        case edit(String)
    }

    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @AppStorage("setupComplete") private var setupComplete = false
    @StateObject private var viewModel: CredentialListViewModel
    @StateObject private var addVM: AddCredentialViewModel
    @ObservedObject private var approvals = ApprovalCenter.shared
    @ObservedObject private var ipcServer: IPCServer
    @ObservedObject private var inbox = UICommandInbox.shared
    @State private var page: Page = .home
    @FocusState private var searchFocused: Bool
    /// The latest name/notes edit made by an agent or script, until dismissed.
    @State private var latestChange: MetadataChangeRecord?
    @State private var cliState: CLIInstallState = .current(installed: "")
    @State private var cliError: String?
    @AppStorage("lastSeenMetadataChange") private var lastSeenChange = ""

    private let session: any CredentialSessionManaging
    private var importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?
    private var openMainWindow: (MainWindowRouter.Section?, String?) -> Void
    private var reopenPopover: () -> Void
    private let services: PopoverHomeServices

    init(session: any CredentialSessionManaging,
         ipcServer: IPCServer,
         importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)? = nil,
         openMainWindow: @escaping (MainWindowRouter.Section?, String?) -> Void = { _, _ in },
         reopenPopover: @escaping () -> Void = {},
         listModel: CredentialListViewModel? = nil,
         addModel: AddCredentialViewModel? = nil,
         services: PopoverHomeServices = .production) {
        self.session = session
        self.ipcServer = ipcServer
        self.importFile = importFile
        self.openMainWindow = openMainWindow
        self.reopenPopover = reopenPopover
        self.services = services
        _viewModel = StateObject(wrappedValue: listModel ?? CredentialListViewModel(session: session))
        _addVM = StateObject(wrappedValue: addModel ?? AddCredentialViewModel(session: session, approvals: .shared))
    }

    var body: some View {
        Group {
            if !setupComplete {
                SetupView(
                    setupComplete: $setupComplete,
                    keyCount: viewModel.loadFailure == nil && viewModel.hasLoaded ? viewModel.credentials.count : nil,
                    onAddKey: {
                        // Starting the first key is the end of the guide; an unsaved draft is kept.
                        setupComplete = true
                        if !addVM.hasDraft { addVM.reset() }
                        page = .add
                    },
                    onOpenSettings: { openMainWindow(.settings, nil) },
                    onOpenAccess: { openMainWindow(.access, nil) }
                )
                .onAppear { viewModel.load() }
            } else {
                switch page {
                case .home:
                    home
                case .add:
                    AddCredentialView(
                        vm: addVM,
                        onSave: {
                            let id = addVM.credentialId
                            viewModel.load()
                            addVM.reset()
                            page = .detail(id)
                            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                        },
                        onCancel: { page = .home },
                        onOpenExisting: { id in
                            addVM.reset()
                            page = .detail(id)
                        },
                        onImportFile: importFile,
                        afterFilePicker: reopenPopover
                    )
                case .detail(let id):
                    // An agent may have renamed it while it was open; old IDs still find it.
                    if let item = viewModel.credentials.first(where: { $0.id == id })
                        ?? viewModel.credentials.first(where: { $0.credential.aliases?.contains(id) == true }) {
                        PopoverKeyDetail(
                            credentialId: item.id,
                            credential: item.credential,
                            session: session,
                            valueAvailability: viewModel.valueAvailability[item.id] ?? .init(state: .unchecked),
                            valueHints: viewModel.valueHints[item.id] ?? [:],
                            onCheckValues: { viewModel.load() },
                            onBack: { page = .home },
                            onOpenWindow: { openMainWindow(.keys, item.id) },
                            onEdit: { page = .edit(item.id) }
                        )
                        .id(item.id)
                    } else {
                        home
                    }
                case .edit(let id):
                    // 【曾经的 bug】2026-11-07 yyt：菜单栏里只能看、不能改，要改得开主窗口再找一遍。
                    if let item = viewModel.credentials.first(where: { $0.id == id }) {
                        CredentialDetailView(
                            credentialId: item.id,
                            credential: item.credential,
                            session: session,
                            onBack: { page = .detail(item.id) },
                            onUpdate: {
                                viewModel.load()
                                page = .detail(item.id)
                                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                            },
                            onDelete: { nil },
                            onRenamed: { page = .detail($0) },
                            startEditing: true
                        )
                        .id(item.id)
                    } else {
                        home
                    }
                }
            }
        }
        // The popover's own glass alone is too clear over a bright window behind it: white text
        // on white. The design system's base veil keeps it legible in both appearances.
        .background(PopoverVeil())
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
        // Handled on the outer body so a link that arrived before the popover was ever
        // rendered is still picked up on first render.
        .onReceive(inbox.$pendingAddCredential.compactMap { $0 }) { link in
            if case .addCredential(let label, let fields, let notes) = link {
                addVM.prefill(label: label, fields: fields, notes: notes)
                page = .add
            }
            DispatchQueue.main.async { inbox.clearAddCredential() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardCredentialSaved)) { _ in viewModel.load() }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in viewModel.load() }
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("KeyKeeper").font(.system(size: 15, weight: .bold))
                Spacer()
                PopoverIconButton(symbol: "plus", help: L("Add a key")) {
                    if !addVM.hasDraft { addVM.reset() }
                    page = .add
                }
                PopoverIconButton(symbol: "macwindow", help: L("Open KeyKeeper")) { openMainWindow(nil, nil) }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField(L("Search \(viewModel.credentials.count) keys"), text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .frame(height: 32)
            .surface(.inset, radius: 16)

            if !approvals.items.isEmpty {
                waitingSection
            }

            if let proposal = BrowserImportProposalDisplay.recoverable(ipcServer.browserImportProposal) {
                BrowserImportProposalNotice(
                    proposal: proposal,
                    onReview: { ipcServer.reopenBrowserImportProposal(id: proposal.id) },
                    onCancel: { ipcServer.cancelBrowserImportProposal(id: proposal.id) }
                )
            }

            if !approvals.missed.isEmpty || approvals.missedLoadFailed || UserDefaults.standard.bool(forKey: "missedApprovalRecordError") {
                missedSection
            }

            if let change = latestChange, change.id != lastSeenChange {
                changeNotice(change)
            }

            if cliState.needsAttention {
                cliNotice
            }

            list

            footer
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .frame(width: DS.Popover.width)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            viewModel.load()
            addVM.refreshExistingIds()
            searchFocused = true
            latestChange = services.latestChange()
            cliState = services.probeCLI()
            services.refreshMissed(approvals)
        }
        .onReceive(NotificationCenter.default.publisher(for: .metadataEditedByCaller)) { note in
            latestChange = note.object as? MetadataChangeRecord
        }
    }

    /// A command-line tool that does not match the app used to be discoverable only from a row
    /// in Settings — yyt 2026-09-13: 「这个谁能发现得了这个更新入口」. It belongs where people
    /// actually look. One click fixes it for good: the new install is a symlink that follows
    /// every future update.
    @ViewBuilder
    private var cliNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "terminal.fill").font(.system(size: 18)).foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(cliNoticeTitle)
                    .font(.callout.weight(.semibold)).lineLimit(1)
                Text(L("Agents use it to reach KeyKeeper. Installing it once now also keeps it current after every update."))
                    .font(.caption).foregroundColor(.secondary).lineLimit(3)
            }
            Spacer(minLength: 4)
            Button(cliState.actionLabel ?? L("Install")) {
                cliError = CLIInstaller.installWithAdminPrivileges().map { AppL10n.text($0) }
                cliState = CLIInstallState.probe(appVersion: BuildVersion.identifier)
            }
        }
        .padding(12)
        .surface(.card, radius: 14)
    }

    private var cliNoticeTitle: String {
        switch cliState {
        case .stale: return L("The keykeeper command is from an older version")
        case .missing: return L("The keykeeper command is not installed")
        default: return cliState.title
        }
    }

    /// No prompt when an agent renames or re-describes a key; it is said here instead.
    private func changeNotice(_ record: MetadataChangeRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "pencil.circle.fill").font(.system(size: 18)).foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(MetadataEditCopy.headline(record)).font(.callout.weight(.semibold)).lineLimit(1)
                Text(record.changes.map(MetadataEditCopy.text).joined(separator: " · "))
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button { lastSeenChange = record.id } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(L("Dismiss"))
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { lastSeenChange = record.id; openMainWindow(.activity, nil) }
        .surface(.card, radius: 14)
    }

    /// One grouped container with hairlines inset past the avatar, like the system list.
    @ViewBuilder
    private var list: some View {
        let items = viewModel.filtered
        if viewModel.metadataTampered {
            Text(L("Your credential list was changed outside KeyKeeper. Open the KeyKeeper window to check it."))
                .font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
        }
        if let failure = viewModel.loadFailure {
            CredentialListFailureNotice(reason: failure.reason, hasLastKnownRows: !viewModel.credentials.isEmpty,
                                        retry: viewModel.load)
        }
        if items.isEmpty && viewModel.loadFailure == nil {
            Text(viewModel.credentials.isEmpty
                 ? L("No keys yet. Press + to store your first one.")
                 : L("No key matches \"\(viewModel.searchText)\"."))
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .surface(.card, radius: 14)
        } else if !items.isEmpty {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PopoverKeyRow(credential: item.credential, subtitle: subtitle(item.id, item.credential),
                                      valueAvailability: viewModel.valueAvailability[item.id] ?? .init(state: .unchecked)) {
                            page = .detail(item.id)
                        }
                        .disabled(viewModel.loadFailure != nil)
                        if index < items.count - 1 {
                            GlassSeparator().padding(.leading, 58).padding(.trailing, 14)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: min(CGFloat(items.count) * PopoverKeyRow.height + 8, PopoverKeyRow.height * 5.5 + 8))
            .surface(.card, radius: 14)
        }
    }

    private func subtitle(_ id: String, _ credential: Credential) -> String {
        if CredentialKind(credential) == .serviceAccountFile {
            return L("Service-account JSON file")
        }
        return ValueHintText.listSubtitle(credential.fieldSummary, credential: credential, hints: viewModel.valueHints[id] ?? [:])
    }

    // MARK: Waiting for you

    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        TimelineView(.periodic(from: item.shownAt, by: 0.25)) { context in
                            Button(action: item.confirm) {
                                Text(item.opensWindow ? "\(item.confirmTitle)…" : item.confirmTitle)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(item.destructive ? .red : .accentColor)
                            .controlSize(.small)
                            .disabled(!item.canConfirm(now: context.date))
                        }
                    }
                }
                .padding(12)
                .surface(.attention, radius: 14)
            }
        }
    }

    private var missedSection: some View {
        MissedApprovalNotice(
            event: approvals.missed.first,
            credentialLabel: approvals.missed.first.map { event in
                viewModel.credentials.first { $0.id == event.credentialId }?.credential.label ?? event.credentialId
            },
            count: approvals.missed.count,
            loadFailed: approvals.missedLoadFailed,
            recordFailed: UserDefaults.standard.bool(forKey: "missedApprovalRecordError"),
            onHistory: { openMainWindow(.activity, nil) },
            onDismiss: { approvals.dismissMissed(id: $0) },
            onDismissWarning: {
                UserDefaults.standard.set(false, forKey: "missedApprovalRecordError")
                approvals.refreshMissed()
            }
        )
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button { NSApplication.shared.terminate(nil) } label: {
                Label(L("Quit KeyKeeper"), systemImage: "power")
            }
            .buttonStyle(.plain)
            .help(L("KeyKeeper starts again automatically the next time a key is requested."))
            Spacer()
            Button { openMainWindow(.settings, nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help(L("Settings"))
        }
        .font(.caption)
        .foregroundColor(.secondary)
        .padding(.horizontal, 4)
        .frame(height: 26)
    }
}

/// A finished request is information, not an approval action. Kept separate so synthetic UI
/// fixtures can render it without loading the real vault or the real approval store.
struct MissedApprovalNotice: View {
    let event: ServiceAuditEvent?
    let credentialLabel: String?
    let count: Int
    let loadFailed: Bool
    let recordFailed: Bool
    let onHistory: () -> Void
    let onDismiss: (String) -> Void
    let onDismissWarning: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let event, let id = event.requestID {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "clock.badge.exclamationmark").foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Missed approval request")).font(.callout.weight(.semibold))
                        Text(verbatim: CallerStatedReason.printableLine(event.subjectDisplayName, limit: 60)
                            + " · " + (credentialLabel ?? event.credentialId))
                            .font(.caption).lineLimit(2)
                        Text(L("That command has ended. Ask the Agent to try again."))
                            .font(.caption).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    if count > 1 {
                        Text(L("\(count) missed requests"))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(L("View history"), action: onHistory).controlSize(.small)
                    Button(L("Got it")) { onDismiss(id) }.controlSize(.small)
                }
            }
            if loadFailed || recordFailed {
                Label(L("Some missed requests could not be saved or loaded. Check Keychain access."), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
                if recordFailed {
                    Button(L("Dismiss warning"), action: onDismissWarning).controlSize(.small)
                }
            }
        }
        .padding(12)
        .surface(.attention, radius: 14)
    }

}

private struct PopoverVeil: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Glass.fill(.base, scheme).ignoresSafeArea()
    }
}

/// Plain header icon, the size of the system menu bar extras' + and window buttons.
struct PopoverIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// "‹ Back" in the top-left of a menu bar sub-page.
struct PopoverBackButton: View {
    let action: () -> Void

    var body: some View {
        PopoverBarButton(symbol: "chevron.left", title: L("Back"), action: action)
    }
}

/// A word in a menu bar page's top bar ("‹ Back", "Edit"): accent-coloured text, no border,
/// a light wash on hover, like the links in a system window's title bar.
///
/// 【曾经的 bug】2026-11-07 yyt 盘点：「返回」是个带边框的大胶囊，比页面标题还抢眼。
struct PopoverBarButton: View {
    var symbol: String?
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)) }
                Text(title).font(.system(size: 13))
            }
            .foregroundColor(.accentColor)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Rounded letter tile, like the system Passwords list.
/// Text keys get their first letter on grey (as in the system list); service-account files
/// get a document on blue and website sessions a globe on teal, so a file key never looks
/// like a key whose value went missing (yyt 2026-09-11).
struct KeyAvatar: View {
    enum Kind: Equatable { case text, file, session, provider(String) }

    let label: String
    var kind: Kind = .text
    var size: CGFloat = 32

    init(label: String, kind: Kind = .text, size: CGFloat = 32) {
        self.label = label
        self.kind = kind
        self.size = size
    }

    init(credential: Credential, size: CGFloat = 32) {
        let kind: Kind
        if CredentialKind(credential) == .serviceAccountFile { kind = .file }
        else if let provider = credential.provider, ProviderCatalog.find(provider) != nil { kind = .provider(provider) }
        else { kind = .text }
        self.init(label: credential.label, kind: kind, size: size)
    }

    var body: some View {
        Group {
            switch kind {
            case .provider(let id):
                // yyt 2026-09-15: a dark mark on the grey tile looked wrong next to the white
                // letters. A provider tile is white with the mark in its brand colour, like an icon.
                ProviderMark(providerId: id, size: size * 0.58, colored: true, onLightSurface: true)
            case .text:
                Text(label.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: size * 0.55, weight: .regular))
                    .foregroundColor(.white)
            case .file:
                Image(systemName: "doc.text.fill").font(.system(size: size * 0.46)).foregroundColor(.white)
            case .session:
                Image(systemName: "globe").font(.system(size: size * 0.5)).foregroundColor(.white)
            }
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(tint))
        .overlay {
            if case .provider = kind {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
        .help(kind == .file ? L("Service-account JSON file") : kind == .session ? L("Website session") : "")
    }

    private var tint: Color {
        switch kind {
        case .text: return Color.gray.opacity(0.6)
        case .provider: return Color.white
        case .file: return Color.blue.opacity(0.72)
        case .session: return Color.teal.opacity(0.8)
        }
    }
}

/// What the menu bar home reads from outside itself when it appears. Renders and tests pass
/// synthetic ones, so they never read the real change log, CLI install or approvals.
struct PopoverHomeServices {
    var latestChange: @MainActor () -> MetadataChangeRecord?
    var probeCLI: @MainActor () -> CLIInstallState
    var refreshMissed: @MainActor (ApprovalCenter) -> Void

    static var production: PopoverHomeServices {
        PopoverHomeServices(latestChange: { (try? MetadataChangeLog.default.records())?.last },
                            probeCLI: { CLIInstallState.probe(appVersion: BuildVersion.identifier) },
                            refreshMissed: { $0.refreshMissed() })
    }
}

struct PopoverKeyRow: View {
    static let height: CGFloat = 54
    let credential: Credential
    let subtitle: String
    var valueAvailability: CredentialValueAvailability = .init(state: .unchecked)
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                KeyAvatar(credential: credential)
                VStack(alignment: .leading, spacing: 1) {
                    Text(credential.label).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                CredentialAvailabilityBadge(availability: valueAvailability, compact: true)
                // The main window's list says "Expires in 13 days"; here, the same fact as an icon.
                if let expiry = ExpiryPresentation.badge(credential.expires) {
                    Image(systemName: "calendar.badge.exclamationmark")
                        .font(.system(size: 12))
                        .foregroundColor(expiry.isExpired ? .red : .orange)
                        .help(expiry.label)
                        .accessibilityLabel(expiry.label)
                }
                if credential.security == .strict {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                        .help(SecurityLevelPresentation.badge(.strict))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.06 : 0)).padding(.horizontal, 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One key, the way the system shows one password: a grouped card of label → value rows,
/// then the one thing to do with it here — hand it to your agent. Edit opens the shared
/// editor in place; the main window is for permissions, history and deleting.
struct PopoverKeyDetail: View {
    let credentialId: String
    var valueAvailability: CredentialValueAvailability
    /// Field name → last four characters of its stored value, when long enough.
    var valueHints: [String: String]
    var onCheckValues: () -> Void
    @StateObject private var vm: CredentialDetailViewModel
    var onBack: () -> Void
    var onOpenWindow: () -> Void
    /// Opens this key in the editor, right here in the menu bar.
    var onEdit: (() -> Void)?
    @State private var copiedIndex: Int?
    @State private var copiedPrompt = false
    @State private var summaries: [String: ServiceAccountSummary] = [:]

    init(credentialId: String, credential: Credential, session: any CredentialSessionManaging,
         valueAvailability: CredentialValueAvailability = .init(state: .unchecked),
         valueHints: [String: String] = [:],
         onCheckValues: @escaping () -> Void = {},
         onBack: @escaping () -> Void, onOpenWindow: @escaping () -> Void, onEdit: (() -> Void)? = nil) {
        self.credentialId = credentialId
        self.onEdit = onEdit
        self.valueAvailability = valueAvailability
        self.valueHints = valueHints
        self.onCheckValues = onCheckValues
        _vm = StateObject(wrappedValue: CredentialDetailViewModel(credentialId: credentialId, credential: credential, session: session, approvals: .shared))
        self.onBack = onBack
        self.onOpenWindow = onOpenWindow
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PopoverBackButton(action: onBack)
                Spacer()
                if let onEdit {
                    PopoverBarButton(title: L("Edit"), action: onEdit)
                }
                PopoverIconButton(symbol: "macwindow", help: L("Open in KeyKeeper"), action: onOpenWindow)
            }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    KeyAvatar(credential: vm.credential, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.credential.label).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        Text(L("Updated \(RecentCredentials.dayLabel(for: vm.credential.updated))"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 12)

                if CredentialAvailabilityBadge.isShown(valueAvailability) {
                    GlassSeparator()
                    HStack {
                        CredentialAvailabilityBadge(availability: valueAvailability)
                        Spacer()
                        Button(L("Check again"), action: onCheckValues).font(.caption)
                    }
                    .padding(.vertical, 6)
                }
                ForEach(Array(vm.fields.enumerated()), id: \.offset) { index, field in
                    GlassSeparator()
                    if field.fileFormat != nil {
                        fileRows(field)
                    } else {
                        HStack(spacing: 10) {
                            FieldNameLabel(field: field, credential: vm.credential)
                            Spacer(minLength: 12)
                            fieldValue(index: index, field: field)
                        }
                        .frame(minHeight: 40)
                        .padding(.vertical, 2)
                        .contextMenu { fieldMenu(index: index, field: field) }
                    }
                }
                if !vm.credential.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    GlassSeparator()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Note for your agent")).font(.callout)
                        Text(NoteText.attributed(vm.credential.notes))
                            .font(.callout).foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 10)
                }
                // What scripts pass to keykeeper run -c: needed now and then, so last and quiet.
                GlassSeparator()
                row(L("Group ID")) {
                    Text(credentialId).font(.callout.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                    CopyTextButton(text: credentialId, help: L("Copy group ID"))
                }
                .foregroundColor(.secondary)
                .help(L("The name scripts and agents pass to keykeeper run -c. It is not a key name."))
            }
            .padding(.horizontal, 14)
            .surface(.card, radius: 14)

            if copiedIndex != nil {
                Text(L("Copied. The clipboard clears itself in \(Int(SecretPasteboard.clearDelay)) s unless you copy something else."))
                    .font(.caption2).foregroundColor(.secondary)
            }

            Button {
                PlainPasteboard.copy(AgentPromptCopy.prompt(credentialId: credentialId, credential: vm.credential))
                copiedPrompt = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedPrompt = false }
            } label: {
                Label(copiedPrompt ? L("Copied") : L("Copy prompt for your agent"),
                      systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text(L("Paste the prompt into your agent. It gets the key's name, never its value."))
                .font(.caption2).foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(14)
        .frame(width: DS.Popover.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A service-account file: what it is, that its contents stay hidden, and the two
    /// non-secret facts people need (the robot's email to grant access to, and its project).
    @ViewBuilder
    private func fileRows(_ field: FieldEntry) -> some View {
        row(field.name, monospaced: true, symbol: "doc.text") {
            Text(L("Service-account JSON file")).font(.callout).foregroundColor(.secondary)
            Image(systemName: "lock.fill").font(.caption).foregroundColor(.secondary)
        }
        .help(L("The file's contents are never shown or copied. Agents use it through keykeeper run --file, which hands the process a private temporary file."))
        .task { if summaries[field.name] == nil, let s = vm.serviceAccountSummary(fieldName: field.name) { summaries[field.name] = s } }
        if let summary = summaries[field.name] {
            GlassSeparator()
            row("client_email", monospaced: true) {
                Text(summary.clientEmail).font(.callout).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                CopyTextButton(text: summary.clientEmail, help: L("Copy value"))
            }
            if let project = summary.projectId {
                GlassSeparator()
                row("project_id", monospaced: true) {
                    Text(project).font(.callout).foregroundColor(.secondary).textSelection(.enabled)
                    CopyTextButton(text: project, help: L("Copy value"))
                }
            }
        }
    }

    @ViewBuilder
    private func fieldMenu(index: Int, field: FieldEntry) -> some View {
        Button(L("Copy field name")) { PlainPasteboard.copy(field.name) }
        Button(L("Copy environment variable name")) { PlainPasteboard.copy(EnvironmentVariableName.from(fieldName: field.name)) }
        Button(L("Copy value")) { copyValue(index: index, field: field) }
    }

    private func copyValue(index: Int, field: FieldEntry) {
        if let value = vm.copyFieldValue(field.name) {
            let changeCount = SecretPasteboard.write(value)
            SecretPasteboard.scheduleClear(after: changeCount)
            copiedIndex = index
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if copiedIndex == index { copiedIndex = nil }
            }
        }
    }

    private func row<Value: View>(_ label: String, monospaced: Bool = false, symbol: String? = nil,
                                  @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            if let symbol {
                Image(systemName: symbol).foregroundColor(.secondary)
            }
            Text(label).font(monospaced ? .callout.monospaced() : .callout).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            value()
        }
        .frame(minHeight: 40)
    }

    @ViewBuilder
    private func fieldValue(index: Int, field: FieldEntry) -> some View {
        if field.fileFormat != nil {
            Text(L("Service-account JSON")).font(.callout).foregroundColor(.secondary)
        } else {
            HStack(spacing: 8) {
                Text(field.visible && !field.value.isEmpty ? field.value : (valueAvailability.missingFields.contains(field.name) ? L("Value missing") : ValueHintText.masked(valueHints[field.name])))
                    .font(.callout.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button { vm.toggleFieldVisibility(at: index) } label: {
                    Image(systemName: field.visible ? "eye.slash" : "eye")
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help(field.visible ? L("Hide") : L("Show"))
                Button { copyValue(index: index, field: field) } label: {
                    Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .foregroundColor(copiedIndex == index ? .green : .secondary)
                .help(L("Copy value (clipboard is cleared after \(Int(SecretPasteboard.clearDelay)) s)"))
            }
        }
    }
}

enum CredentialDeletionCopy {
    static let template = "Its key values are removed from the macOS Keychain. This can't be undone, and anything running `keykeeper run -c {0}` will stop working."

    static func message(credentialId: String) -> String {
        AppL10n.render(template, arguments: [credentialId], language: AppL10n.language)
    }
}

/// Small copy icon for non-secret text (IDs, names, the service account's email).
struct CopyTextButton: View {
    let text: String
    let help: String
    @State private var copied = false

    var body: some View {
        Button {
            PlainPasteboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.plain)
        .foregroundColor(copied ? .green : .secondary)
        .help(help)
    }
}
