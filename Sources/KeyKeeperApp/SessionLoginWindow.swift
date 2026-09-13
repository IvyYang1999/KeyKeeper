import AppKit
import WebKit
import KeyKeeperCore

/// Logging in to a website inside KeyKeeper, with no browser extension involved.
///
/// The window starts empty — its data store is non-persistent and nothing from Chrome, Safari or
/// any other KeyKeeper session is in it. You log in the way you normally would, press Save, and
/// KeyKeeper keeps the cookies for the site you named. Closing the window without saving throws
/// everything away.
///
/// The session this produces is independent of your browser: signing out in Chrome does not
/// invalidate it, and this login does not disturb the one you already have there.
@MainActor final class SessionLoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let origin: String
    private let window: NSWindow
    private let statusLabel = NSTextField(labelWithString: "")
    private var webView: WKWebView?
    private let onSave: ([CapturedCookie]) -> Void
    private let onClose: () -> Void
    private var closed = false

    init(origin: String, label: String,
         onSave: @escaping ([CapturedCookie]) -> Void,
         onClose: @escaping () -> Void) {
        self.origin = origin
        self.onSave = onSave
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "KeyKeeper · \(L("Log in to \(label)"))"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 720, height: 560)

        let config = WKWebViewConfiguration()
        // Empty and forgetful: nothing of yours is in here, and nothing stays behind.
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web

        let save = NSButton(title: L("Save this login"), target: self, action: #selector(saveTapped))
        save.keyEquivalent = "\r"
        save.bezelStyle = .rounded
        let cancel = NSButton(title: L("Discard"), target: self, action: #selector(cancelTapped))
        cancel.bezelStyle = .rounded
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.stringValue = origin

        let bar = NSStackView(views: [statusLabel, NSView(), cancel, save])
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [bar, web])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.distribution = .fill
        bar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        window.contentView = stack
    }

    func show() {
        guard let web = webView, let url = URL(string: origin + "/") else { return }
        web.load(URLRequest(url: url))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func saveTapped() {
        guard let web = webView else { return }
        Task { @MainActor [weak self] in
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
            guard let self, !self.closed else { return }
            self.onSave(cookies.map(Self.captured))
            self.shutdown()
        }
    }

    @objc private func cancelTapped() { shutdown() }

    /// Everything WebKit knows about one cookie, with none of KeyKeeper's opinions applied yet —
    /// which cookies are worth keeping is `BrowserSessionCapture`'s question, and it is tested
    /// without a web view.
    static func captured(_ cookie: HTTPCookie) -> CapturedCookie {
        let sameSite: String
        switch cookie.sameSitePolicy {
        case .some(.sameSiteStrict): sameSite = "strict"
        case .some(.sameSiteLax): sameSite = "lax"
        default: sameSite = "unspecified"
        }
        return CapturedCookie(name: cookie.name, value: cookie.value, domain: cookie.domain,
                              path: cookie.path, secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly,
                              sameSite: sameSite,
                              expiresAt: cookie.expiresDate?.timeIntervalSince1970)
    }

    func shutdown() {
        guard !closed else { return }
        closed = true
        if let web = webView {
            web.stopLoading()
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.configuration.websiteDataStore.removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            web.removeFromSuperview()
        }
        webView = nil
        window.close()
        onClose()
    }

    func windowWillClose(_ notification: Notification) { shutdown() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, SessionBrowserPolicy.allowsDuringLogin(url) else {
            decisionHandler(.cancel); return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Always say where you are: this window may leave the site you named, and you should be
        // able to see that at a glance.
        statusLabel.stringValue = webView.url?.host.map { "https://" + $0 } ?? origin
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Popup logins open in the same window rather than an unmanaged one.
        if let url = action.request.url, SessionBrowserPolicy.allowsDuringLogin(url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
