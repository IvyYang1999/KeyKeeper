import AppKit
import SwiftUI
import KeyKeeperCore

enum BrowserSessionCopy {
    static func action(_ action: BrowserSessionRequest.Action) -> String {
        switch action {
        case .save: return L("Save website login state?")
        case .open: return L("Open an isolated logged-in window?")
        case .delete: return L("Remove this saved login state?")
        case .list, .stop: return L("Website sessions")
        }
    }
    static func error(_ error: BrowserSessionError) -> String {
        switch error {
        case .unsupported: return L("This login state uses Cookie settings this macOS adapter cannot preserve. Nothing was imported. Keep the original Chrome login.")
        case .invalidImport: return L("This login state is not supported. Only the selected HTTPS site and unpartitioned root-path Cookies are accepted.")
        case .denied: return L("Request cancelled.")
        case .busy: return L("Finish the current confirmation or close the existing session window first.")
        case .expired: return L("This request or login state expired. Import a fresh snapshot from Chrome.")
        case .disconnected: return L("The caller disconnected. No pending action was approved.")
        case .conflict: return L("This session ID already exists with different data. Nothing was overwritten.")
        case .notFound: return L("Saved website session not found.")
        case .capacity: return L("Session limit reached. Remove an unused snapshot or close a window first.")
        case .unavailable: return L("The website session store or browser is unavailable. No automatic reset was attempted. Do not blindly retry an uncertain import.")
        }
    }
}

@MainActor final class BrowserSessionFeature {
    let controller: BrowserSessionController?
    let store: BrowserSessionStore?
    private let approval = BrowserSessionApprovalWindow()
    init() {
        let approval = self.approval
        store = try? BrowserSessionStore.production()
        if let store {
            controller = BrowserSessionController(store: store, runtime: SessionBrowserRuntime(),
                present: { approval.show($0, decide: $1) }, dismiss: { approval.dismiss() },
                presentWithDuration: { approval.show($0, decideDuration: $1) }, approvals: .shared)
        } else { controller = nil }
    }
}

/// The main window's "Website sessions" page. It used to be its own 720×540 window opened
/// from a globe button in the menu bar; now it is a page beside the keys it relates to.
struct BrowserSessionManagerView: View {
    @ObservedObject var controller: BrowserSessionController
    @State private var setup = BrowserExtensionSetup.production()
    @State private var showingLogin = false
    @State private var loginSite = ""
    @State private var loginLabel = ""
    @State private var loginError: String?
    @State private var loginWindow: SessionLoginWindow?
    @State private var lastSuggestedLabel = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    MainPageHeader(
                        title: L("Website sessions"),
                        subtitle: L("Let an agent use a website you are already logged in to, without handing over your password. Opening a window needs your approval — once, for an hour, or always, for that agent. Windows pause after 15 minutes until authorized again, and inside one an agent can do anything you could, not just read.")
                    )
                    Spacer()
                    if !controller.sessions.isEmpty {
                        Button(L("Stop all windows")) { controller.stopAll() }
                    }
                }
                if controller.sessions.isEmpty {
                    BrowserSessionStartCard(setup: $setup, onLogIn: { showingLogin = true })
                } else {
                    VStack(spacing: 10) {
                        ForEach(controller.sessions) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 10) {
                                    KeyAvatar(label: item.label, kind: .session, size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(CallerStatedReason.printableLine(item.label, limit: 80)).font(.callout.weight(.semibold))
                                        Text(item.origin).font(.caption.monospaced()).foregroundColor(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    Spacer()
                                    Button(L("Open isolated window")) { send(.open, id: item.id) }
                                    Button(L("Stop window")) { send(.stop, id: item.id) }
                                    Button(L("Remove snapshot…")) { send(.delete, id: item.id) }
                                        .foregroundColor(.red)
                                }
                                Text("keykeeper browser open \(item.id)")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                // Anyone given more than "once" is listed here, with the way to take it back:
                                // an approval nobody can see or revoke is not one anybody really gave.
                                ForEach(controller.approvals(for: item.id)) { approval in
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark.shield").foregroundColor(.secondary)
                                        Text(SessionGrantCopy.line(approval))
                                            .font(.caption).foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer()
                                        Button(L("Revoke")) { controller.revokeApproval(id: approval.id) }
                                            .buttonStyle(.link).font(.caption)
                                    }
                                }
                            }
                            .padding(14)
                            .glassCard()
                        }
                    }
                }
                if !controller.sessions.isEmpty {
                    HStack(spacing: 10) {
                        Button(L("Log in to another site here")) { showingLogin = true }
                        BrowserExtensionStatusLine(setup: $setup)
                    }
                }
                if let error = controller.errorCode {
                    Text(BrowserSessionCopy.error(error)).font(.callout).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("Stopping or removing a snapshot does not log out Chrome or revoke the website's server-side session."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)
            .sheet(isPresented: $showingLogin) { loginSheet }
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear { controller.refresh() }
    }

    private func send(_ action: BrowserSessionRequest.Action, id: String) {
        controller.receive(.init(action: action, id: id), caller: "KeyKeeper") { _ in }
    }

    /// Signing in here instead of importing from Chrome. No extension is involved, and the
    /// session it makes is independent: signing out in Chrome will not invalidate it.
    private var loginSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Log in inside KeyKeeper")).font(.headline)
            Text(L("A window opens with nothing in it — none of your browser's logins. Sign in there, press Save, and KeyKeeper keeps that site's session. This does not touch the login you already have in your browser."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("https://example.com", text: $loginSite)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced())
                .onChange(of: loginSite) { _, typed in
                    loginError = nil
                    // The name is the site until someone says otherwise; nobody should have to
                    // invent one to get past this sheet.
                    if let suggested = BrowserSessionImport.suggestedLabel(forOrigin: typed),
                       loginLabel.isEmpty || loginLabel == lastSuggestedLabel {
                        loginLabel = suggested
                        lastSuggestedLabel = suggested
                    }
                }
            TextField(L("A name you will recognise"), text: $loginLabel)
                .textFieldStyle(.roundedBorder)
            if let loginError {
                Text(loginError).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { showingLogin = false; loginError = nil }
                Button(L("Open the login window")) { startLogin() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(BrowserSessionImport.normalizeOrigin(loginSite) == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func startLogin() {
        let label = loginLabel.isEmpty ? (BrowserSessionImport.suggestedLabel(forOrigin: loginSite) ?? "") : loginLabel
        guard let origin = BrowserSessionImport.normalizeOrigin(loginSite), !label.isEmpty else {
            loginError = L("That does not look like a website address. Use the site's home address, like example.com.")
            return
        }
        loginError = nil
        showingLogin = false
        let window = SessionLoginWindow(origin: origin, label: label, onSave: { cookies in
            do {
                let snapshot = try BrowserSessionCapture.snapshot(origin: origin, label: label, cookies: cookies)
                try controller.saveLocalLogin(snapshot)
                loginSite = ""; loginLabel = ""
            } catch {
                loginError = L("Nothing was saved: no usable login was found for that site. Sign in first, then press Save.")
                showingLogin = true
            }
        }, onClose: { loginWindow = nil })
        loginWindow = window
        window.show()
    }
}

@MainActor private final class BrowserSessionApprovalWindow {
    private let presenter = TrustPromptPresenter()

    func show(_ info: BrowserSessionPresentation, decide: @escaping (Bool) -> Void) {
        // The controller gives each request 90 seconds from the moment it is received,
        // which is also when it is presented.
        presenter.show(.browserSession(info, expiresAt: Date().addingTimeInterval(90)),
                       symbol: "globe", decide: decide)
    }

    func show(_ info: BrowserSessionPresentation, decideDuration: @escaping (ApprovalDuration?) -> Void) {
        presenter.show(.browserSession(info, expiresAt: Date().addingTimeInterval(90)),
                       symbol: "globe", decideDuration: decideDuration)
    }

    func dismiss() { presenter.dismiss() }
}

/// The first thing anyone sees on this page, and for a long time the only thing: it used to open
/// with a three-step Chrome developer-mode procedure and never said what the feature was for.
///
/// Lead with the two ways in, shortest first. The Chrome route's setup stays folded away until
/// someone picks it — it is a real procedure, but it is not the point of the page.
struct BrowserSessionStartCard: View {
    @Binding var setup: BrowserExtensionSetup
    var onLogIn: () -> Void
    @State private var showingChromeSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: "person.badge.key",
                title: L("Log in here"),
                detail: L("KeyKeeper opens an empty window. You sign in there once, and it keeps that session. Nothing to install."),
                button: L("Start"),
                action: onLogIn)
            GlassSeparator()
            chromeRow
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private var chromeRow: some View {
        switch setup.connection {
        case .missingFromApp:
            row(symbol: "puzzlepiece.extension",
                title: L("Bring one over from Chrome"),
                detail: L("This copy of KeyKeeper does not contain the Chrome extension. Reinstall it from keykeeper.dev."),
                button: nil, action: {})
        case .registered:
            row(symbol: "puzzlepiece.extension",
                title: L("Bring one over from Chrome"),
                detail: L("Open the site in Chrome, click the KeyKeeper extension, pick that site and confirm here."),
                button: nil, action: {})
        case .notRegistered, .tamperedWith, .moved:
            VStack(alignment: .leading, spacing: 10) {
                row(symbol: setup.connection == .notRegistered ? "puzzlepiece.extension" : "exclamationmark.triangle",
                    title: setup.connection == .tamperedWith
                        ? L("Chrome is wired to something else")
                        : setup.connection == .moved ? L("KeyKeeper has moved since Chrome was connected") : L("Bring one over from Chrome"),
                    detail: setup.connection == .tamperedWith
                        ? L("KeyKeeper's registration file now points at another program. Something changed it. Register again to point it back.")
                        : setup.connection == .moved
                            ? L("The registration still points at KeyKeeper's old location. Register again to point it here.")
                            : L("Reuse a site you are already signed in to in Chrome. Needs a one-time setup."),
                    button: showingChromeSteps ? L("Hide") : L("Set up"),
                    action: { showingChromeSteps.toggle() })
                if showingChromeSteps {
                    BrowserExtensionSetupCard(setup: $setup, showsNextStep: false)
                }
            }
        }
    }

    private func row(symbol: String, title: String, detail: String,
                     button: String?, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundColor(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.callout).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let button { Button(button, action: action) }
        }
        .padding(.vertical, 8)
    }
}

/// One line under the list, for when the page is no longer empty.
struct BrowserExtensionStatusLine: View {
    @Binding var setup: BrowserExtensionSetup

    var body: some View {
        switch setup.connection {
        case .registered:
            Text(L("Chrome is registered. Use the extension there to bring another site over."))
                .font(.caption).foregroundColor(.secondary)
        case .tamperedWith, .moved:
            // Once snapshots exist this line is all the page shows about Chrome, so it carries the fix.
            // 【独立审计第二轮】it used to be red text with no way to act on it.
            HStack(spacing: 8) {
                Text(setup.connection == .moved ? L("KeyKeeper has moved since Chrome was connected") : L("Chrome is wired to something else"))
                    .font(.caption).foregroundColor(setup.connection == .moved ? .orange : .red)
                Button(L("Register again")) {
                    try? setup.connect(replacingExisting: true)
                    setup = setup
                }
                .buttonStyle(.link).font(.caption)
            }
        case .notRegistered, .missingFromApp:
            EmptyView()
        }
    }
}

/// The Chrome side of the setup: where the extension is, and wiring it to this Mac.
struct BrowserExtensionSetupCard: View {
    @Binding var setup: BrowserExtensionSetup
    var showsNextStep: Bool
    @State private var failure: String?

    var body: some View {
        switch setup.connection {
        case .missingFromApp:
            EmptyGlassCard(
                symbol: "puzzlepiece.extension",
                title: L("This build has no browser extension"),
                text: L("Website sessions need the Chrome extension that ships inside KeyKeeper.app, and this copy does not contain it. Reinstall KeyKeeper from keykeeper.dev.")
            )
        case .notRegistered, .tamperedWith, .moved:
            connectCard
        case .registered(let id):
            if showsNextStep { nextStepCard(id: id) }
        }
    }

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("Connect Chrome first"), systemImage: "puzzlepiece.extension").font(.headline)
            Text(L("This needs a Chrome extension. It is not in the Chrome Web Store — it ships inside KeyKeeper.app, so you load it yourself: open chrome://extensions, turn on Developer mode, choose \"Load unpacked\" and pick this folder."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(L("Show the extension folder")) { setup.revealExtensionFolder() }
                Button(L("Copy the folder path")) { copy(setup.extensionFolder?.path ?? "") }
                Button(L("Copy chrome://extensions")) { copy("chrome://extensions") }
            }
            GlassSeparator()
            Text(L("Then let KeyKeeper register the connection. Its extension ID is fixed, so there is nothing to copy."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(setup.connection == .notRegistered ? L("Register the connection") : L("Register again")) {
                    connect(replacing: BrowserExtensionSetup.registrationReplacesExisting(setup.connection))
                }
                    .disabled(setup.expectedExtensionID == nil)
                if let id = setup.expectedExtensionID {
                    Text(id).font(.caption.monospaced()).foregroundColor(.secondary).textSelection(.enabled)
                }
            }
            if let failure {
                Text(failure).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func nextStepCard(id: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L("No website sessions yet"), systemImage: "globe").font(.headline)
            Text(L("Open the intended website in Chrome and click the KeyKeeper extension. Pick that site, name it, and confirm here. Keep your original browser login."))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                // Registered, not "connected": KeyKeeper wrote this registration and Chrome never
                // writes back, so it cannot tell whether the extension is still installed.
                Text(L("Registered for extension \(id). KeyKeeper cannot see whether Chrome still has it installed."))
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L("Register again")) { connect(replacing: true) }
                    .buttonStyle(.link).font(.caption)
            }
            if let failure {
                Text(failure).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func connect(replacing: Bool) {
        do {
            try setup.connect(replacingExisting: replacing)
            failure = nil
            setup = setup   // re-read the registration so the card switches state
        } catch {
            failure = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// One line per standing approval on the sessions page.
enum SessionGrantCopy {
    static func line(_ approval: Approval) -> String {
        let who = CallerStatedReason.printableLine(approval.subject.displayName, limit: 80)
        switch approval.duration {
        case .always:
            return L("\(who) can open it without asking")
        case .process:
            return L("\(who) can open it without asking while it runs")
        case .timed(let until):
            let formatter = DateFormatter()
            formatter.locale = AppL10n.locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return L("\(who) can open it without asking until \(formatter.string(from: until))")
        case .once:
            return L("\(who) can open it once more without asking")
        case .terminalSession:
            return L("\(who) can open it without asking")
        }
    }
}

