import AppKit
import WebKit
import KeyKeeperCore

enum SessionBrowserPolicy {
    static func allows(_ url: URL, origin: String) -> Bool {
        guard let selected = URLComponents(string: origin), let target = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return target.scheme == selected.scheme && target.host == selected.host
            && (target.port ?? 443) == (selected.port ?? 443) && target.user == nil && target.password == nil
    }
    static func cookie(_ input: BrowserSessionCookie, origin: String) throws -> HTTPCookie {
        // Foundation on supported systems cannot reliably round-trip explicit None.
        // Refuse before saving instead of silently changing the site's authentication policy.
        guard input.sameSite != "no_restriction" else { throw BrowserSessionError.unsupported }
        let url = URL(string: origin)!
        var header = input.name + "=" + input.value + "; Path=/; Secure"
        if input.httpOnly { header += "; HttpOnly" }
        do {
            // Chrome's unspecified policy is Lax-by-default; do not widen it in WebKit.
            let mapped = ["lax": "Lax", "strict": "Strict", "unspecified": "Lax"]
            guard let sameSite = mapped[input.sameSite] else { throw BrowserSessionError.invalidImport }
            header += "; SameSite=" + sameSite
        }
        if let expiry = input.expirationDate {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            header += "; Expires=" + formatter.string(from: Date(timeIntervalSince1970: expiry))
        }
        guard let result = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": header], for: url).first,
              result.domain == url.host, result.isHTTPOnly == input.httpOnly, result.isSecure,
              result.name == input.name, result.value == input.value else { throw BrowserSessionError.invalidImport }
        let expectedPolicy = input.sameSite == "unspecified" ? "lax" : input.sameSite
        guard result.sameSitePolicy?.rawValue.lowercased() == expectedPolicy else { throw BrowserSessionError.unsupported }
        return result
    }
}

@MainActor final class SessionBrowserRuntime: BrowserSessionRuntime {
    private var windows: [String: IsolatedSessionWindow] = [:]
    // Dependency injection for an isolated, pinned-certificate integration fixture.
    // Production has no evaluator and always uses normal system TLS verification.
    private let trustEvaluator: ((URLProtectionSpace) -> Bool)?
    init(trustEvaluator: ((URLProtectionSpace) -> Bool)? = nil) { self.trustEvaluator = trustEvaluator }
    var activeIDs: [String] { windows.keys.sorted() }
    func validate(_ snapshot: BrowserSessionImport) throws {
        try snapshot.validate()
        for item in snapshot.cookies { _ = try SessionBrowserPolicy.cookie(item, origin: snapshot.origin) }
    }
    func open(_ snapshot: BrowserSessionImport, completion: @escaping (Bool) -> Void) {
        do { try validate(snapshot) } catch { completion(false); return }
        guard windows.count < 2, windows[snapshot.id] == nil else { completion(false); return }
        let window = IsolatedSessionWindow(origin: snapshot.origin, label: snapshot.label, trustEvaluator: trustEvaluator) { [weak self] in
            self?.windows.removeValue(forKey: snapshot.id)
        }
        windows[snapshot.id] = window
        window.prepare(snapshot.cookies) { [weak self, weak window] ok in
            guard let self, let window, self.windows[snapshot.id] === window else { return }
            if !ok { self.stop(id: snapshot.id) }
            completion(ok)
        }
    }
    func stop(id: String) { windows.removeValue(forKey: id)?.shutdown() }
    func stopAll() { for id in activeIDs { stop(id: id) } }
}

@MainActor private final class IsolatedSessionWindow: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    private let origin: String
    private let window: NSWindow
    private var webView: WKWebView?
    private let onClose: () -> Void
    private var timer: Timer?
    private var closed = false
    private let trustEvaluator: ((URLProtectionSpace) -> Bool)?
    init(origin: String, label: String, trustEvaluator: ((URLProtectionSpace) -> Bool)?, onClose: @escaping () -> Void) {
        self.origin = origin; self.onClose = onClose
        self.trustEvaluator = trustEvaluator
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "KeyKeeper · \(origin) · \(L("Ends in 15 minutes"))"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 640, height: 480)
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]; web.navigationDelegate = self; web.uiDelegate = self
        window.contentView = web; webView = web
    }
    func prepare(_ cookies: [BrowserSessionCookie], completion: @escaping (Bool) -> Void) {
        guard let web = webView else { completion(false); return }
        let allowed = "^" + NSRegularExpression.escapedPattern(for: origin) + "/"
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": allowed, "url-filter-is-case-sensitive": true], "action": ["type": "ignore-previous-rules"]]
        ]
        let ruleID = "keykeeper-session-" + UUID().uuidString
        do {
            let converted = try cookies.map { try SessionBrowserPolicy.cookie($0, origin: origin) }
            let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: ruleID, encodedContentRuleList: encoded) { [weak self] rules, _ in
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: ruleID) { _ in }
                guard let self, !self.closed, let rules else { completion(false); return }
                web.configuration.userContentController.add(rules)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for cookie in converted {
                        guard !self.closed else { return }
                        await web.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                    }
                    guard !self.closed else { return }
                    // Verify in process before navigating. Never return the installed values.
                    let installed = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
                    guard installed.count == converted.count, converted.allSatisfy({ expected in
                        installed.contains { $0.name == expected.name && $0.value == expected.value && $0.domain == expected.domain && $0.isHTTPOnly == expected.isHTTPOnly && $0.isSecure && $0.sameSitePolicy == expected.sameSitePolicy }
                    }) else { completion(false); return }
                    guard !self.closed else { return }
                    web.load(URLRequest(url: URL(string: self.origin + "/")!))
                    self.window.center(); self.window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                    self.timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: false) { [weak self] _ in
                        Task { @MainActor in self?.shutdown() }
                    }
                    completion(true)
                }
            }
        } catch { completion(false) }
    }
    func shutdown() {
        guard !closed else { return }; closed = true; timer?.invalidate(); timer = nil
        if let web = webView {
            web.stopLoading(); web.navigationDelegate = nil; web.uiDelegate = nil
            web.configuration.userContentController.removeAllContentRuleLists()
            web.configuration.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            web.removeFromSuperview()
        }
        webView = nil; window.close(); onClose()
    }
    func windowWillClose(_ notification: Notification) { shutdown() }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust, trustEvaluator?(challenge.protectionSpace) == true {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else { completionHandler(.performDefaultHandling, nil) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard !closed, action.targetFrame != nil, !action.shouldPerformDownload,
              let url = action.request.url, SessionBrowserPolicy.allows(url, origin: origin) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        guard response.canShowMIMEType, let url = response.response.url,
              SessionBrowserPolicy.allows(url, origin: origin) else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
