import AppKit
import WebKit
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Opt-in render of the browser paste page in an offscreen WebKit view. Synthetic request, a closed
/// local port and no clipboard: the states are driven through the page's own functions.
@MainActor final class BrowserImportPageVisualTests: XCTestCase {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    func test粘贴页四种状态中英文浅深色() async throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_BROWSER_PAGE_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic browser page render")
        }
        _ = NSApplication.shared
        let request = ClipboardSaveRequest(credentialId: "openai-synthetic", fieldName: "api-key", create: true)
        let states: [(String, String?)] = [
            ("1-paste", nil),
            ("2-confirm", "render({state:'pasteReceived'})"),
            ("3-saved", "render({state:'committed'})"),
            ("4-cancelled", "stop(\(BrowserImportPage.scriptString("Import cancelled. You can close this page.")))"),
        ]
        for (language, dark) in [("zh-Hans", false), ("zh-Hans", true), ("en", false), ("en", true)] {
            let html = BrowserImportPage.html(request: request, language: language)
            for (name, script) in states {
                let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 620, height: 760),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 620, height: 760))
                web.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = web
                let loaded = Loaded()
                web.navigationDelegate = loaded
                await withCheckedContinuation { continuation in
                    loaded.done = continuation
                    web.loadHTMLString(html, baseURL: URL(string: "http://127.0.0.1:9/#" + String(repeating: "a", count: 64)))
                }
                if var script {
                    if language == "zh-Hans", name == "4-cancelled" {
                        script = "stop(\(BrowserImportPage.scriptString(AppL10n.render("Import cancelled. You can close this page.", language: "zh-Hans"))))"
                    }
                    _ = try await web.evaluateJavaScript(script)
                }
                try await Task.sleep(nanoseconds: 300_000_000)
                let image = try await web.takeSnapshot(configuration: nil)
                let rep = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
                try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(
                        "browser-\(language)-\(dark ? "dark" : "light")-\(name).png"))
                window.close()
            }
        }
    }
}
