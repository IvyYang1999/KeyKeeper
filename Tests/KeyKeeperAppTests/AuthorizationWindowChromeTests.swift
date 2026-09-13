import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class AuthorizationWindowChromeTests: XCTestCase {
    /// 【曾经的 bug】yyt 2026-09-13：「展开调用详情之后，弹窗又变成这个奇怪的直角了」。
    /// 展开「调用方详情」后窗口会跟着长高，但磨砂是贴在内容盒上的，窗口多出来的那块没有玻璃，
    /// 于是底部露出直角的实色底。磨砂必须铺满整个宿主视图，窗口多高都一样。
    func test曾经的Bug窗口比内容高时磨砂仍铺满整窗() throws {
        let hosting = NSHostingView(rootView: Self.authorizationView())
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 900)
        hosting.layoutSubtreeIfNeeded()

        let effects = Self.visualEffectViews(in: hosting)
        XCTAssertFalse(effects.isEmpty, "授权窗应该有磨砂层")
        let covers = effects.contains { effect in
            let rect = effect.convert(effect.bounds, to: hosting)
            return rect.width >= hosting.bounds.width - 1 && rect.height >= hosting.bounds.height - 1
        }
        XCTAssertTrue(covers, "磨砂层没铺满窗口，实际：\(effects.map { $0.convert($0.bounds, to: hosting) })")
    }

    /// 同一个病在保存确认面板上也成立：它同样是透明窗 + 可展开的「详细说明」。
    func test保存确认面板的磨砂也铺满整窗() throws {
        let model = TrustPromptModel.save(.init(
            request: ClipboardSaveRequest(credentialId: "cloudflare-billing", fieldName: "api-token", create: true),
            callerName: "com.openai.codex"
        ))
        let hosting = NSHostingView(rootView: TrustPromptView(model: model, onCancel: {}, onConfirm: {}))
        hosting.frame = NSRect(x: 0, y: 0, width: 440, height: 900)
        hosting.layoutSubtreeIfNeeded()

        let effects = Self.visualEffectViews(in: hosting)
        XCTAssertTrue(effects.contains { effect in
            let rect = effect.convert(effect.bounds, to: hosting)
            return rect.width >= hosting.bounds.width - 1 && rect.height >= hosting.bounds.height - 1
        }, "保存面板的磨砂没铺满窗口，实际：\(effects.map { $0.convert($0.bounds, to: hosting) })")
    }

    private static func authorizationView() -> AuthorizationView {
        AuthorizationView(
            prompt: .strict(AuthRequest(credentialId: "cloudflare-billing",
                                        credentialLabel: "cloudflare-billing",
                                        fieldNames: ["api-token"],
                                        sessionId: nil, sessionLabel: nil, pid: 1)),
            onAuthorizeGrant: { _ in },
            onAuthorizeService: nil,
            onDeny: {}
        )
    }

    private static func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        var found: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView { found.append(effect) }
        for sub in view.subviews { found += visualEffectViews(in: sub) }
        return found
    }
}
