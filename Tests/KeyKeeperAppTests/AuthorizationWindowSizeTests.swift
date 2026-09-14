import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【曾经的 bug】yyt 2026-09-14 截图：授权窗内容只占上半截，窗口却一路拉到屏幕底（实测 420×932）。
/// 走的是 AuthorizationWindowController 真实的开窗路径，不是自己拼的窗。
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
        // Note: the test host has no NSApplication, so AppKit's own "resize the window to the
        // hosting view's ideal size" pass never runs here. That pass is what grew the window in
        // the app; this test only pins the heights the view reports.
        let controller = AuthorizationWindowController()
        controller.show(request: strictRequest(), onAuthorize: { _ in }, onDeny: {})
        defer { controller.dismiss() }
        let window = try XCTUnwrap(controller.window)
        let atShow = try XCTUnwrap(window.contentView).bounds.height
        // Past the settle delay: the first re-render after showing is when the window used to grow.
        RunLoop.current.run(until: Date().addingTimeInterval(ApprovalReadiness.settleDelay + 0.6))
        let settled = try XCTUnwrap(window.contentView).bounds.height
        XCTAssertLessThan(atShow, 640, "刚打开就 \(atShow)pt")
        XCTAssertLessThan(settled, 640, "冷静期过后长到 \(settled)pt：内容只有半截，其余是空白")
        XCTAssertEqual(settled, atShow, accuracy: 2, "冷静期结束不该改变窗口高度")
    }
}
