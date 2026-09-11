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

@MainActor private final class BrowserSessionApprovalWindow: NSObject, NSWindowDelegate {
    private var panel: BrowserSessionApprovalPanel?
    private var decide: ((Bool) -> Void)?
    func show(_ info: BrowserSessionPresentation, decide: @escaping (Bool) -> Void) {
        self.decide = decide
        let panel = BrowserSessionApprovalPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        self.panel = panel; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.title = L("KeyKeeper — Website session")
        panel.level = .floating; panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.resolve(false) }
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: panel.contentView!.bottomAnchor, constant: -24)
        ])
        func text(_ value: String, heading: Bool = false) {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = heading ? .boldSystemFont(ofSize: 20) : .systemFont(ofSize: 13)
            stack.addArrangedSubview(label); label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        text(BrowserSessionCopy.action(info.action), heading: true)
        text(info.session.origin, heading: true)
        text(L("Requested by: \(info.caller)"))
        text(L("Profile label: \(info.session.label) · \(info.session.cookieCount) Cookies"))
        text(info.action == .delete
             ? L("This stops the managed window and deletes only this saved snapshot. Chrome and the website account remain unchanged.")
             : L("This can grant account actions, not just reading. Only this site opens in a temporary window; cross-site navigation and file uploads are blocked. Closing it does not revoke the website session."))
        text(L("One request only · expires in 90 seconds · Cookie values are never returned to the caller."))
        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked)); cancel.keyEquivalent = "\r"
        let allow = NSButton(title: L("Confirm once"), target: self, action: #selector(allowClicked))
        stack.addArrangedSubview(NSStackView(views: [cancel, allow]))
        panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func cancelClicked() { resolve(false) }
    @objc private func allowClicked() { resolve(true) }
    private func resolve(_ approved: Bool) { let reply = decide; decide = nil; reply?(approved) }
    func windowWillClose(_ notification: Notification) { resolve(false) }
    func dismiss() { decide = nil; panel?.close(); panel = nil }
}

@MainActor private final class BrowserSessionApprovalPanel: NSPanel {
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
