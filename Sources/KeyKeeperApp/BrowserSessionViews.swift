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
    private let approval = BrowserSessionApprovalWindow()
    private var manager: NSWindow?
    init() {
        let approval = self.approval
        if let store = try? BrowserSessionStore.production() {
            controller = BrowserSessionController(store: store, runtime: SessionBrowserRuntime(),
                present: { approval.show($0, decide: $1) }, dismiss: { approval.dismiss() })
        } else { controller = nil }
    }
    func show() {
        guard let controller else { return }
        controller.refresh()
        if let manager { manager.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L("Website sessions"); window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 440)
        let hosting = NSHostingView(rootView: BrowserSessionManagerView(controller: controller))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 720, height: 540))
        manager = window; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

private struct BrowserSessionManagerView: View {
    @ObservedObject var controller: BrowserSessionController
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Website sessions")).font(.title2.weight(.semibold))
                Spacer()
                Button(L("Refresh")) { controller.refresh() }
                Button(L("Stop all windows")) { controller.stopAll() }
            }
            Text(L("Import only a website you select in the Chrome extension. Each open needs your confirmation and ends after 15 minutes. Account actions are NOT read-only."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if controller.sessions.isEmpty {
                Spacer()
                Text(L("No website sessions yet")).font(.headline)
                Text(L("Open the intended website in Chrome, then use the KeyKeeper extension to request an import. Keep your original browser login."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(controller.sessions) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.label).font(.headline)
                                Text(item.origin).textSelection(.enabled)
                                Text("keykeeper browser open \(item.id)").font(.caption.monospaced()).textSelection(.enabled)
                                HStack {
                                    Button(L("Open isolated window")) { send(.open, id: item.id) }
                                    Button(L("Stop window")) { send(.stop, id: item.id) }
                                    Spacer()
                                    Button(L("Remove snapshot…")) { send(.delete, id: item.id) }
                                }.buttonStyle(.bordered)
                            }.padding(.vertical, 8)
                        }
                    }
                }
            }
            if let error = controller.errorCode {
                Text(BrowserSessionCopy.error(error)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("Stopping or removing a snapshot does not log out Chrome or revoke the website's server-side session."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24)
    }
    private func send(_ action: BrowserSessionRequest.Action, id: String) {
        controller.receive(.init(action: action, id: id), caller: "KeyKeeper") { _ in }
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

    func dismiss() { presenter.dismiss() }
}
