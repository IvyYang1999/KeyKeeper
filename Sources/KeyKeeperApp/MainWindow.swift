import AppKit
import SwiftUI
import KeyKeeperCore

/// Where the main window is pointed. Shared so the menu bar, deep links and the status menu
/// can all say "show this" without owning the window.
@MainActor
final class MainWindowRouter: ObservableObject {
    static let shared = MainWindowRouter()

    enum Section: String, CaseIterable, Identifiable {
        case keys, sessions, access, activity, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .keys: return L("Keys")
            case .sessions: return L("Website sessions")
            case .access: return L("Usage permissions")
            case .activity: return L("Access log")
            case .settings: return L("Settings")
            }
        }

        var symbol: String {
            switch self {
            case .keys: return "key.horizontal"
            case .sessions: return "globe"
            case .access: return "checkmark.shield"
            case .activity: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    @Published var section: Section = .keys
    @Published var selectedCredentialId: String?
    @Published var isAdding = false

    init() {}

    func show(section: Section, credentialId: String? = nil) {
        self.section = section
        if let credentialId {
            selectedCredentialId = credentialId
            isAdding = false
        }
    }
}

/// The Dock half of KeyKeeper: everything you go and do on purpose — find, edit, see who is
/// approved, revoke, website sessions, settings. The menu bar keeps the "right now" half.
///
/// KeyKeeper is a menu bar (accessory) app. While this window is open it becomes a regular
/// app, so it has a Dock icon, ⌘Tab and the standard menus; closing the window drops it back
/// to the menu bar only.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeContent: () -> AnyView
    private let router: MainWindowRouter
    private let frameAutosaveName: String?
    private let presentWindow: (NSWindow) -> Void

    init(router: MainWindowRouter = .shared, frameAutosaveName: String? = "KeyKeeperMainWindow",
         presentWindow: @escaping (NSWindow) -> Void = MainWindowController.present,
         makeContent: @escaping () -> AnyView) {
        self.router = router
        self.frameAutosaveName = frameAutosaveName
        self.presentWindow = presentWindow
        self.makeContent = makeContent
    }

    var isVisible: Bool { window?.isVisible == true }

    func show(section: MainWindowRouter.Section? = nil, credentialId: String? = nil) {
        if let section { router.show(section: section, credentialId: credentialId) }
        let window = self.window ?? makeWindow()
        self.window = window
        presentWindow(window)
    }

    private static func present(_ window: NSWindow) {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = "KeyKeeper"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 820, height: 520)
        window.isReleasedWhenClosed = false
        if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
        window.delegate = self
        // Esc from a focused field reaches the key editor (and does nothing extra elsewhere).
        let hosting = EscapeRoutingHostingView(rootView: makeContent())
        hosting.sizingOptions = []
        window.contentView = hosting
        if let frameAutosaveName, !window.setFrameUsingName(frameAutosaveName) { window.center() }
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // UI automation keeps the app regular (see AppDelegate); otherwise go back to the menu bar.
        if ProcessInfo.processInfo.environment["KEYKEEPER_UI_TEST_REGULAR"] == nil {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Root view

struct MainWindowView: View {
    @AppStorage(AppL10n.preferenceName) private var interfaceLanguage = "system"
    @ObservedObject var router: MainWindowRouter
    @ObservedObject var updateController: UpdateController
    let session: any CredentialSessionManaging
    let browserSessions: BrowserSessionController?
    var importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?
    var onShowSetup: () -> Void

    @StateObject private var listVM: CredentialListViewModel
    @StateObject private var addVM: AddCredentialViewModel
    /// Nil in the app (each page uses the real store); renders pass synthetic ones.
    private let metaStore: MetaStore?
    private let approvals: ApprovalStore

    init(router: MainWindowRouter, updateController: UpdateController, session: any CredentialSessionManaging,
         browserSessions: BrowserSessionController?,
         importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?,
         onShowSetup: @escaping () -> Void,
         listModel: CredentialListViewModel? = nil, metaStore: MetaStore? = nil, approvals: ApprovalStore = .shared) {
        self.router = router
        self.updateController = updateController
        self.session = session
        self.browserSessions = browserSessions
        self.importFile = importFile
        self.onShowSetup = onShowSetup
        self.metaStore = metaStore
        self.approvals = approvals
        _listVM = StateObject(wrappedValue: listModel ?? CredentialListViewModel(session: session))
        _addVM = StateObject(wrappedValue: metaStore.map { AddCredentialViewModel(session: session, store: $0, approvals: approvals) }
                             ?? AddCredentialViewModel(session: session, approvals: approvals))
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
            GlassSeparator(vertical: true)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .glassWindowBackground()
        .environment(\.panelLayout, .embedded)
        .environment(\.locale, AppL10n.locale(preference: interfaceLanguage))
        .onAppear { listVM.load() }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardCredentialSaved)) { _ in listVM.load() }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsChanged)) { _ in listVM.load() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The title bar safe area already clears the traffic lights; 12 matches the list
            // column's top padding so the first item lines up with the search field.
            Color.clear.frame(height: 9) // + 3 stack spacing = 12
            ForEach([MainWindowRouter.Section.keys, .sessions, .access, .activity], id: \.self) { section in
                sidebarItem(section, count: count(for: section))
            }
            Spacer()
            sidebarItem(.settings, count: nil)
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 10)
    }

    private func count(for section: MainWindowRouter.Section) -> Int? {
        switch section {
        case .keys: return listVM.credentials.count
        case .sessions: return browserSessions?.sessions.count
        default: return nil
        }
    }

    private func sidebarItem(_ section: MainWindowRouter.Section, count: Int?) -> some View {
        let selected = router.section == section
        return Button {
            router.section = section
        } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .foregroundColor(section == .settings ? .secondary : .accentColor)
                    .frame(width: 18)
                Text(section.title)
                    .fontWeight(selected ? .semibold : .regular)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)").font(.caption).foregroundColor(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background(
                Group { if selected { Color.clear.surface(.raised, radius: 9) } }
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch router.section {
        case .keys:
            KeysPage(router: router, listVM: listVM, addVM: addVM, session: session, importFile: importFile,
                     metaStore: metaStore, approvals: approvals)
        case .sessions:
            if let browserSessions {
                BrowserSessionManagerView(controller: browserSessions)
                    .padding(.top, 12)
            } else {
                UnavailablePage(text: L("The website session store or browser is unavailable. No automatic reset was attempted. Do not blindly retry an uncertain import."))
            }
        case .access:
            ApprovedCallersPage(credentials: listVM.credentials, onOpenCredential: showCredential)
        case .activity:
            AccessLogPage(credentials: listVM.credentials, onOpenCredential: showCredential)
        case .settings:
            SettingsView(
                updateController: updateController,
                onShowServiceGrants: { router.section = .access },
                onShowSetup: onShowSetup
            )
            .padding(.top, 12)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func showCredential(_ id: String) {
        guard let current = listVM.credentials.first(where: { $0.id == id || $0.credential.aliases?.contains(id) == true }) else { return }
        router.show(section: .keys, credentialId: current.id)
    }
}

extension Notification.Name {
    /// Posted after any credential is added, edited or deleted from a window other than the one showing it.
    static let credentialsChanged = Notification.Name("KeyKeeper.credentialsChanged")
}

private struct UnavailablePage: View {
    let text: String
    var body: some View {
        VStack { Spacer(); Text(text).foregroundColor(.secondary).padding(40); Spacer() }
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Keys

private struct KeysPage: View {
    @ObservedObject var router: MainWindowRouter
    @ObservedObject var listVM: CredentialListViewModel
    @ObservedObject var addVM: AddCredentialViewModel
    let session: any CredentialSessionManaging
    var importFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?
    var metaStore: MetaStore?
    var approvals: ApprovalStore
    @State private var pendingDeleteId: String?

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 280)
            GlassSeparator(vertical: true)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Nothing stored yet (and nothing failed to load): no search box for zero keys, and the
    /// right side offers the first one instead of "Choose a key on the left".
    private var hasNoKeys: Bool { listVM.credentials.isEmpty && listVM.loadFailure == nil }

    private func startAdding() {
        addVM.reset()
        router.isAdding = true
        router.selectedCredentialId = nil
    }

    private var list: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if hasNoKeys {
                    Spacer()
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                        TextField(KeySearchPlaceholder.text(count: listVM.credentials.count), text: $listVM.searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .surface(.inset, radius: 9)
                }

                Button(action: startAdding) {
                    Image(systemName: "plus").frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .glassCard(radius: 9)
                .help(L("New key group"))
                .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.top, 12)

            if listVM.metadataTampered {
                MetadataTamperNotice { listVM.trustCurrentMetadata() }
            }
            if let failure = listVM.loadFailure {
                CredentialListFailureNotice(reason: failure.reason, hasLastKnownRows: !listVM.credentials.isEmpty,
                                            retry: listVM.load)
            }
            if listVM.credentials.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(listVM.filtered, id: \.id) { item in
                            row(item.id, item.credential)
                                .disabled(listVM.loadFailure != nil)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 12)
        .confirmationDialog(
            L("Delete \"\(label(for: pendingDeleteId))\"?"),
            isPresented: Binding(get: { pendingDeleteId != nil }, set: { if !$0 { pendingDeleteId = nil } }),
            titleVisibility: .visible
        ) {
            Button(L("Delete"), role: .destructive) {
                if let id = pendingDeleteId, listVM.delete(id: id), router.selectedCredentialId == id {
                    router.selectedCredentialId = nil
                }
                pendingDeleteId = nil
            }
            Button(L("Cancel"), role: .cancel) { pendingDeleteId = nil }
        } message: {
            Text(CredentialDeletionCopy.message(credentialId: pendingDeleteId ?? ""))
        }
    }

    private func row(_ id: String, _ credential: Credential) -> some View {
        let selected = router.selectedCredentialId == id && !router.isAdding
        return Button {
            router.isAdding = false
            router.selectedCredentialId = id
        } label: {
            HStack(spacing: 10) {
            KeyAvatar(credential: credential, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                // Name and tags on one line when they fit; a long name keeps the room and the tags
                // become icons (words in the tooltip) instead of folding into three lines.
                // 【曾经的 bug】2026-11-08 渲染发现：长名字时「每次询问」「8 天后过期」折成三行。
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(credential.label).font(.callout.weight(.semibold)).lineLimit(1)
                        if credential.security == .strict { SecurityBadge(level: .strict).fixedSize().layoutProbe("list.badge") }
                        ExpiryBadge(expires: credential.expires).fixedSize().layoutProbe("list.badge")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Text(credential.label).font(.callout.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 0)
                        if credential.security == .strict { SecurityBadge(level: .strict, compact: true).layoutProbe("list.badge") }
                        ExpiryBadge(expires: credential.expires, compact: true).layoutProbe("list.badge")
                    }
                }
                HStack {
                    Text(subtitle(id, credential))
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    CredentialAvailabilityBadge(availability: listVM.valueAvailability[id] ?? .init(state: .unchecked), compact: true)
                }
            }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassCard(radius: 11, selected: selected)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("Copy prompt for your agent")) {
                PlainPasteboard.copy(AgentPromptCopy.prompt(credentialId: id, credential: credential))
            }
            Divider()
            Button(L("Delete\u{2026}"), role: .destructive) { pendingDeleteId = id }
        }
    }

    private func subtitle(_ id: String, _ credential: Credential) -> String {
        if CredentialKind(credential) == .serviceAccountFile {
            return L("Service-account JSON file")
        }
        return ValueHintText.listSubtitle(credential.fieldSummary, credential: credential, hints: listVM.valueHints[id] ?? [:])
    }

    private func label(for id: String?) -> String {
        guard let id else { return "" }
        return listVM.credentials.first { $0.id == id }?.credential.label ?? id
    }

    @ViewBuilder
    private var detail: some View {
        if router.isAdding {
            AddCredentialView(
                vm: addVM,
                onSave: {
                    let id = addVM.credentialId
                    listVM.load()
                    addVM.reset()
                    router.isAdding = false
                    router.selectedCredentialId = id
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                },
                onCancel: { router.isAdding = false },
                onOpenExisting: { id in
                    addVM.reset()
                    router.isAdding = false
                    router.selectedCredentialId = id
                },
                onImportFile: importFile
            )
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.horizontal, 12)
        } else if let id = router.selectedCredentialId,
                  let item = listVM.credentials.first(where: { $0.id == id })
                    ?? listVM.credentials.first(where: { $0.credential.aliases?.contains(id) == true }) {
            CredentialDetailView(
                credentialId: item.id,
                credential: item.credential,
                session: session,
                valueAvailability: listVM.valueAvailability[item.id] ?? .init(state: .unchecked),
                valueHints: listVM.valueHints[item.id] ?? [:],
                onCheckValues: { listVM.load() },
                onBack: { router.selectedCredentialId = nil },
                onUpdate: {
                    listVM.load()
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                },
                onDelete: {
                    guard listVM.delete(id: item.id) else {
                        return listVM.errorMessage ?? L("Delete failed")
                    }
                    router.selectedCredentialId = nil
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                    return nil
                },
                onRenamed: { newId in
                    listVM.load()
                    router.selectedCredentialId = newId
                    NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                },
                store: metaStore ?? .default,
                approvals: approvals
            )
            .id(item.id)
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 12)
        } else {
            VStack(spacing: 10) {
                Spacer()
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72).opacity(0.9)
                if hasNoKeys {
                    // 【曾经的 bug】2026-11-08 渲染发现：一把 key 都没有时，左边写「还没有密钥」，右边写
                    // 「在左边选一把 key」，左边并没有能选的东西。
                    Text(L("No keys yet")).foregroundColor(.secondary)
                    Button(L("Add a key"), action: startAdding)
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(L("Choose a key on the left")).foregroundColor(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }
}
