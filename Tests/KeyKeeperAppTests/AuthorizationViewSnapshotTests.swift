import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// Opt-in PNGs of the authorization window with synthetic requests. KEYKEEPER_AUTH_PREVIEW=<dir>
@MainActor final class AuthorizationViewSnapshotTests: XCTestCase {
    func test授权窗快照() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_AUTH_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic UI snapshots")
        }
        _ = NSApplication.shared
        let codex = CallerIdentity(peerPID: 4242, executablePath: "/opt/homebrew/bin/codex", bundleIdentifier: "com.openai.codex.cli",
            teamIdentifier: "2DC432GLL2", signingIdentifier: "com.openai.codex.cli",
            subject: .init(kind: .app, fingerprint: "app:2DC432GLL2:com.openai.codex.cli", displayName: "com.openai.codex.cli", detail: "signed"))
        let talkative = AuthorizationPrompt.strict(AuthRequest(credentialId: "vercel-deployments", credentialLabel: "vercel-deployments",
            fieldNames: ["token"], sessionId: "s1", sessionLabel: "Terminal", pid: 4242, callerIdentity: codex,
            statedReason: CallerStatedReason.sanitize("发布用户要求的个人主页产品卡片点击埋点；先创建一次 Vercel 预览部署用于验收"),
            requestedDuration: .once, commandSummary: "sh -c exec npx --yes vercel@60.1.3 deploy --yes --token \"$TOKEN\""))
        let silent = AuthorizationPrompt.strict(AuthRequest(credentialId: "stripe", credentialLabel: "Stripe", fieldNames: ["api-key"],
            sessionId: nil, sessionLabel: nil, pid: 99,
            callerIdentity: CallerIdentity(peerPID: 99, executablePath: "/Users/me/Applications/Dark Console.app/Contents/MacOS/Dark Console",
                bundleIdentifier: "com.darkconstant.console",
                subject: .init(kind: .app, fingerprint: "app:unsigned:path=abc", displayName: "com.darkconstant.console", detail: "unsigned"))))
        for (name, prompt) in [("talkative", talkative), ("silent", silent)] {
            let review = RequestReview.make(prompt: prompt, credential: nil, approvals: nil)
            let root = AuthorizationView(prompt: prompt, onAuthorize: { _ in }, onDeny: {}, review: review)
                .environment(\.colorScheme, .light)
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: .aqua)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("auth-\(name).png"))
        }
    }
}
