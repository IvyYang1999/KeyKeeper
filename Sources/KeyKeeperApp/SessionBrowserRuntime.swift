import AppKit
import WebKit
import KeyKeeperCore

enum SessionBrowserPolicy {
    static func allows(_ url: URL, origin: String) -> Bool {
        guard let selected = URLComponents(string: origin), let target = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return target.scheme == selected.scheme && target.host == selected.host
            && (target.port ?? 443) == (selected.port ?? 443) && target.user == nil && target.password == nil
    }
    /// Navigation while the person is logging in here.
    ///
    /// Playback locks the window to one origin; a login cannot, because almost every login
    /// leaves it — SSO, a verification page, a third-party identity provider. What stays fixed
    /// is that the window starts empty, keeps nothing, and only speaks https, so widening the
    /// range costs nothing that was not already the person's own browsing.
    static func allowsDuringLogin(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && parts.user == nil && parts.password == nil
            && !(parts.host ?? "").isEmpty
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
    /// Asked when a window's time runs out. The window is already frozen by then; answering yes
    /// restarts its clock, answering no closes it.
    private var requestReauthorization: ((String, @escaping (Bool) -> Void) -> Void)?
    func setReauthorizationHandler(_ handler: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        requestReauthorization = handler
    }
    var policy: SessionWindowPolicy = .default
    // Dependency injection for an isolated, pinned-certificate integration fixture.
    // Production has no evaluator and always uses normal system TLS verification.
    private let trustEvaluator: ((URLProtectionSpace) -> Bool)?
    init(trustEvaluator: ((URLProtectionSpace) -> Bool)? = nil) { self.trustEvaluator = trustEvaluator }
    var activeIDs: [String] { windows.keys.sorted() }
    func validate(_ snapshot: BrowserSessionImport) throws {
        try snapshot.validate()
        for item in snapshot.cookies { _ = try SessionBrowserPolicy.cookie(item, origin: snapshot.origin) }
    }
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool = true, completion: @escaping (Bool) -> Void) {
        do { try validate(snapshot) } catch { completion(false); return }
        guard windows.count < 2, windows[snapshot.id] == nil else { completion(false); return }
        let window = IsolatedSessionWindow(
            origin: snapshot.origin, label: snapshot.label, policy: policy,
            trustEvaluator: trustEvaluator,
            onReauthorize: { [weak self] decided in
                guard let self, let ask = self.requestReauthorization else { decided(false); return }
                ask(snapshot.id, decided)
            },
            onClose: { [weak self] in self?.windows.removeValue(forKey: snapshot.id) })
        window.bringToFront = bringToFront
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
    private let policy: SessionWindowPolicy
    private let onReauthorize: (@escaping (Bool) -> Void) -> Void
    private var startedAt = Date()
    private var frozenAt: Date?
    private var veil: SessionExpiryVeil?
    private var asking = false
    /// Added when the window freezes: a rule list that blocks every load, of every type.
    private var freezeRules: WKContentRuleList?
    /// That list, compiled before the page ever loads. 【独立审计 2026-09-13】it used to be compiled
    /// at the moment of freezing, asynchronously, while the veil already said the page could not
    /// reach the network — for that stretch the sentence was false. Compiled up front, freezing
    /// blocks first and only then says so.
    private var freezeList: WKContentRuleList?
    /// Only a window somebody just approved is allowed to take over the screen.
    var bringToFront = true
    init(origin: String, label: String, policy: SessionWindowPolicy = .default,
         trustEvaluator: ((URLProtectionSpace) -> Bool)?,
         onReauthorize: @escaping (@escaping (Bool) -> Void) -> Void = { $0(false) },
         onClose: @escaping () -> Void) {
        self.origin = origin; self.onClose = onClose
        self.policy = policy
        self.onReauthorize = onReauthorize
        self.trustEvaluator = trustEvaluator
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "KeyKeeper · \(origin) · \(L("Ends in 15 minutes"))"
        window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 640, height: 480)
        // A logged-in page should not be readable by every other process's screen capture.
        window.sharingType = .none
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
                let freezeID = "keykeeper-frozen-" + UUID().uuidString
                WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: freezeID, encodedContentRuleList: SessionFreezeRules.encoded
                ) { [weak self] freezeList, _ in
                WKContentRuleListStore.default().removeContentRuleList(forIdentifier: freezeID) { _ in }
                // No honest way to freeze means no session: fail closed before anything loads.
                guard let self, !self.closed, let freezeList else { completion(false); return }
                self.freezeList = freezeList
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
                    self.window.center()
                    if self.bringToFront {
                        self.window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    } else {
                        // Present, findable, but it does not steal what the person is typing into.
                        self.window.orderFrontRegardless()
                    }
                    self.startedAt = Date()
                    // Checked on a tick rather than scheduled once: the deadline moves whenever
                    // someone authorizes again, and a frozen window has its own grace period.
                    self.timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.evaluateLifetime() }
                    }
                    completion(true)
                }
                }
            }
        } catch { completion(false) }
    }
    /// The clock only ends permission. The window and everything in it stay put until either
    /// someone authorizes again or the grace period runs out.
    private func evaluateLifetime() {
        guard !closed else { return }
        switch policy.state(startedAt: startedAt, frozenAt: frozenAt, now: Date()) {
        case .active:
            break
        case .frozen:
            if frozenAt == nil {
                freeze()
                // Ask straight away. A session set to "Background OK" is answered without a
                // prompt, so the veil goes up and comes down in the same turn and nobody sees it.
                renew()
            }
        case .closed:
            shutdown()
        }
    }

    private func freeze() {
        guard veil == nil, let contentView = window.contentView else { return }
        // Block first, synchronously. The veil and its sentence come after, when they are true.
        guard let web = webView, let freezeList else { shutdown(); return }
        web.stopLoading()
        web.configuration.userContentController.add(freezeList)
        freezeRules = freezeList
        frozenAt = Date()
        window.title = "KeyKeeper · \(origin) · \(L("Authorization expired"))"
        let veil = SessionExpiryVeil(
            onRenew: { [weak self] in self?.renew() },
            onClose: { [weak self] in self?.shutdown() })
        veil.frame = contentView.bounds
        veil.autoresizingMask = [.width, .height]
        contentView.addSubview(veil)
        self.veil = veil
    }

    private func renew() {
        guard !asking else { return }
        asking = true
        onReauthorize { [weak self] granted in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                self.asking = false
                guard granted else { self.shutdown(); return }
                self.resumeNetwork()
                self.frozenAt = nil
                self.startedAt = Date()
                self.veil?.removeFromSuperview()
                self.veil = nil
                self.window.title = "KeyKeeper · \(self.origin) · \(L("Ends in 15 minutes"))"
            }
        }
    }

    // Freezing has to mean it, not just look like it: swallowing clicks does nothing about the
    // JavaScript already running in the page, which could keep using the session's cookies for
    // fetch and XHR. SessionFreezeRules blocks every load of every type, so the page can still
    // compute but cannot reach the network, and the cookies stay put instead of being torn out
    // (which the site would see as an immediate logout).

    private func resumeNetwork() {
        guard let list = freezeRules else { return }
        webView?.configuration.userContentController.remove(list)
        freezeRules = nil
    }

    func shutdown() {
        guard !closed else { return }; closed = true; timer?.invalidate(); timer = nil
        freezeRules = nil
        veil?.removeFromSuperview(); veil = nil
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

/// The overlay a frozen session window wears: it covers the page, swallows every click, and
/// offers the only two things that can happen next.
@MainActor private final class SessionExpiryVeil: NSView {
    private let onRenew: () -> Void
    private let onClose: () -> Void

    init(onRenew: @escaping () -> Void, onClose: @escaping () -> Void) {
        self.onRenew = onRenew
        self.onClose = onClose
        super.init(frame: .zero)
        wantsLayer = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.frame = bounds
        effect.autoresizingMask = [.width, .height]
        addSubview(effect)

        let title = NSTextField(labelWithString: L("This authorization has expired"))
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(labelWithString: L("The window and your login are still here, but the page cannot reach the network until you authorize again."))
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.lineBreakMode = .byWordWrapping
        detail.preferredMaxLayoutWidth = 380
        let renew = NSButton(title: L("Authorize again"), target: self, action: #selector(renewTapped))
        renew.keyEquivalent = "\r"
        renew.bezelStyle = .rounded
        let close = NSButton(title: L("Close the window"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded

        let buttons = NSStackView(views: [close, renew])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let stack = NSStackView(views: [title, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
    }

    required init?(coder: NSCoder) { nil }

    /// Nothing behind this reaches the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit ?? self
    }
    override func mouseDown(with event: NSEvent) {}

    @objc private func renewTapped() { onRenew() }
    @objc private func closeTapped() { onClose() }
}

/// The rule list a frozen session window wears: block every load, of every type.
enum SessionFreezeRules {
    static let encoded = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
}
