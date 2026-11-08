import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// 一行一条的访问记录：色点只表达状态，调用方按显示名找到自己的图标。
@MainActor final class ActivityLineTests: XCTestCase {
    func test色点绿色只给已批准的使用橙色给要你看的() {
        XCTAssertEqual(ActivityLine.tone(.approvedUse, status: .notApproved), .good)
        XCTAssertEqual(ActivityLine.tone(.readWithoutApproval, status: .approved), .attention)
        XCTAssertEqual(ActivityLine.tone(.missedApproval, status: .notApproved), .attention)
        XCTAssertEqual(ActivityLine.tone(.approvalRequired, status: .approved), .good, "请求过、现在已授权")
        XCTAssertEqual(ActivityLine.tone(.approvalRequired, status: .notApproved), .off)
        XCTAssertEqual(ActivityLine.tone(.approvalRequired, status: .unavailable), .off)
    }

    func test调用方显示名找到图标用的标识() {
        XCTAssertEqual(CallerAppIcon.lookupId(forName: "Claude Code"), "com.anthropic.claude-code")
        XCTAssertEqual(CallerAppIcon.lookupId(forName: "Codex"), "com.openai.codex")
        XCTAssertEqual(CallerAppIcon.lookupId(forName: "quota-board"), "quota-board", "不认识的名字原样用，显示首字母")
    }
}

/// Opt-in offscreen render of the access history and usage permission pages. In-memory approvals,
/// synthetic credentials and callers only; no window is shown and nothing real is read.
@MainActor final class AccessPagesVisualTests: XCTestCase {
    func test访问记录和使用权限一行一条中英文浅深色() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_ACCESS_PAGES_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic access pages render")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }

        func credential(_ label: String, _ provider: String?) -> Credential {
            Credential(label: label, notes: "", links: [], fields: ["api-key": .init(secret: true)], security: .standard,
                       created: "2026-11-01", updated: "2026-11-01", provider: provider)
        }
        let credentials: [(id: String, credential: Credential)] = [
            ("openai", credential("OpenAI", "openai")), ("stripe-prod", credential("Stripe 生产", "stripe")),
            ("github", credential("GitHub", "github")), ("vercel-deploy", credential("Vercel 部署", "vercel")),
            ("x", credential("X", nil)), ("quota", credential("配额看板", nil)),
        ]
        let now = Date()
        let claude = ApprovalSubject(fingerprint: "app:com.anthropic.claude-code", displayName: "Claude Code")
        let codex = ApprovalSubject(fingerprint: "app:com.openai.codex", displayName: "Codex")
        let cron = ApprovalSubject(fingerprint: "unsigned:path=quota-board", displayName: "quota-board")

        for (language, dark) in [("zh-Hans", false), ("en", true)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let store = ApprovalStore.inMemory()
            try store.setMode(.enforced)
            for (subject, id, minutes) in [(claude, "openai", 5.0), (claude, "stripe-prod", 10), (claude, "github", 20),
                                           (codex, "openai", 12), (codex, "vercel-deploy", 15), (claude, "x", 1)] {
                try store.add(Approval(id: "grant-\(subject.displayName)-\(id)", subject: subject,
                    target: .credential(id: id, fields: nil), duration: .always,
                    createdAt: now.addingTimeInterval(-86_400), lastUsedAt: now.addingTimeInterval(-minutes * 60)))
            }
            try store.add(Approval(id: "grant-expired", subject: cron, target: .credential(id: "quota", fields: nil),
                duration: .timed(now.addingTimeInterval(-3600)), createdAt: now.addingTimeInterval(-7200)))
            try store.recordAudit(.init(timestamp: now.addingTimeInterval(-2), credentialId: "x", fieldName: "api-key",
                subjectFingerprint: claude.fingerprint, subjectDisplayName: claude.displayName, mode: .enforced,
                decision: "prompt_required", requestID: "req-1"))
            for second in [30.0, 90, 150] {
                try store.recordAudit(.init(timestamp: now.addingTimeInterval(-second * 60), credentialId: "quota",
                    fieldName: "api-key", subjectFingerprint: cron.fingerprint, subjectDisplayName: cron.displayName,
                    mode: .enforced, decision: "prompt_required", requestID: "req-cron-\(second)"))
            }
            try store.recordAudit(.init(timestamp: now.addingTimeInterval(-40 * 60), credentialId: "stripe-prod",
                fieldName: "api-key", subjectFingerprint: codex.fingerprint, subjectDisplayName: codex.displayName,
                mode: .enforced, decision: "missed_approval", requestID: "req-missed"))

            let log = AccessLogPage(credentials: credentials, access: AccessLogApprovalState(store: store), loadEdits: { [] })
            let permissions = ApprovedCallersPage(credentials: credentials, state: PermissionPageState(store: store))
            try render(log, name: "access-log-\(language)-\(dark ? "dark" : "light")", dark: dark, language: language, output: output)
            try render(permissions, name: "permissions-\(language)-\(dark ? "dark" : "light")", dark: dark, language: language, output: output)
            // A1: a record selected, its details beside the list, at the width where splitting starts.
            for width in [900.0, 1000, 1100] {
                let selected = AccessLogPage(credentials: credentials, access: AccessLogApprovalState(store: store),
                                             loadEdits: { [] }, selectsFirstRecord: true)
                try render(selected, name: "access-log-selected-\(Int(width))-\(language)-\(dark ? "dark" : "light")",
                           dark: dark, language: language, output: output, size: NSSize(width: width, height: 620))
            }
        }
    }

    private func render<V: View>(_ page: V, name: String, dark: Bool, language: String, output: String,
                                 size: NSSize = NSSize(width: 860, height: 620)) throws {
        let root = page
            .frame(width: size.width, height: size.height)
            .environment(\.panelLayout, .embedded)
            .environment(\.locale, AppL10n.locale(preference: language))
            .environment(\.colorScheme, dark ? .dark : .light)
            .glassWindowBackground()
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        window.close()
    }
}
