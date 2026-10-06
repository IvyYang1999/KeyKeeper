import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【曾经的 bug】yyt 2026-09-14 截图：授权窗内容只占上半截，窗口却一路拉到屏幕底（实测 420×932）。
/// 走 AuthorizationWindowController 真实的内容安装和尺寸计算路径；测试窗不抢前台。
@MainActor
final class AuthorizationWindowSizeTests: XCTestCase {
    private func strictRequest() -> AuthRequest {
        let identity = CallerIdentity(peerPID: 1, executablePath: "/Applications/Codex.app/Contents/MacOS/Codex",
                                      bundleIdentifier: "com.openai.codex",
                                      subject: CallerSubject(kind: .app, fingerprint: CallerSubject.relayedPrefix + "app:team=unsigned:bundle=com.openai.codex:signing=com.openai.codex",
                                                             displayName: "com.openai.codex", detail: ""))
        return AuthRequest(credentialId: "vercel-deployments", credentialLabel: "vercel-deployments",
                           fieldNames: ["token"], sessionId: nil, sessionLabel: nil, pid: 1, callerIdentity: identity)
    }

    func test窗口高度贴着内容而不是可用高度() throws {
        // Exercise the production content-sizing bridge without presenting or activating
        // the test window. AppKit's foreground window pass is not covered here.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 420, height: 460),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        defer { window.close() }
        let view = AuthorizationView(prompt: .strict(strictRequest()), onAuthorize: { _ in }, onDeny: {})
        AuthorizationWindowController.installContent(view, in: window)
        let atShow = try XCTUnwrap(window.contentView).bounds.height
        // Past the settle delay: the first re-render is when the window used to grow.
        RunLoop.current.run(until: Date().addingTimeInterval(ApprovalReadiness.settleDelay + 0.6))
        let settled = try XCTUnwrap(window.contentView).bounds.height
        XCTAssertLessThan(atShow, 640, "刚打开就 \(atShow)pt")
        XCTAssertLessThan(settled, 640, "冷静期过后长到 \(settled)pt：内容只有半截，其余是空白")
        XCTAssertEqual(settled, atShow, accuracy: 2, "冷静期结束不该改变窗口高度")
    }
}
