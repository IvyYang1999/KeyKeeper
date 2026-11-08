import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-08 主力 Mac 验收 A1：访问记录选中一条、右侧详情分栏后，列表里调用方和 key 的名字被挤到
/// 一个字都看不见，只剩图标、状态、时间和「现在批准」。结果、时间、批准按钮和详情都是固定宽，名字却允许零宽。
/// 这里量的是名字实际拿到的宽度，用真的访问记录页、内存授权库和假凭据，窗口在屏幕外。
@MainActor final class AccessLogNarrowLayoutTests: XCTestCase {
    /// About four Chinese characters or eight Latin letters at list size: still says whose and which.
    private let readable: CGFloat = 56

    func test曾经的Bug选中一条分栏后调用方和key的名字仍看得见() throws {
        for language in ["en", "zh-Hans"] {
            for approvable in [true, false] {
                // 900 是开始分栏的宽度；915 是验收时约 1111 点的整窗减去侧栏。
                for (width, select) in [(900.0, true), (915, true), (1000, true), (1100, true), (700, false), (1400, false)] {
                    let widths = try nameWidths(language: language, approvable: approvable, width: width, select: select)
                    let context = "\(language) \(approvable ? "有" : "无")批准按钮 宽 \(Int(width)) \(select ? "选中" : "未选中")：\(widths.map { Int($0) })"
                    XCTAssertGreaterThanOrEqual(widths.count, 6, "每条记录都该量到调用方和 key 两个名字。\(context)")
                    XCTAssertGreaterThanOrEqual(widths.min() ?? 0, readable, "名字被挤得看不见了。\(context)")
                }
            }
        }
    }

    private func nameWidths(language: String, approvable: Bool, width: CGFloat, select: Bool) throws -> [CGFloat] {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)

        func credential(_ label: String, _ provider: String?) -> Credential {
            Credential(label: label, notes: "", links: [], fields: ["api-key": .init(secret: true)], security: .standard,
                       created: "2026-11-01", updated: "2026-11-01", provider: provider)
        }
        let credentials: [(id: String, credential: Credential)] = [
            ("openai", credential("OpenAI 个人项目密钥", "openai")),
            ("stripe-prod", credential("Stripe 生产环境主账号", "stripe")),
            ("quota", credential("配额看板接口密钥", nil)),
        ]
        let now = Date()
        let claude = ApprovalSubject(fingerprint: "app:com.anthropic.claude-code", displayName: "Claude Code")
        let cron = ApprovalSubject(fingerprint: "unsigned:path=quota-board", displayName: "quota-board-nightly-sync")
        let store = ApprovalStore.inMemory()
        try store.setMode(.enforced)
        for (subject, id, minutes) in [(claude, "openai", 5.0), (claude, "stripe-prod", 10), (cron, "openai", 20)] {
            try store.add(Approval(id: "grant-\(subject.displayName)-\(id)", subject: subject,
                target: .credential(id: id, fields: nil), duration: .always,
                createdAt: now.addingTimeInterval(-86_400), lastUsedAt: now.addingTimeInterval(-minutes * 60)))
        }
        if approvable {
            try store.recordAudit(.init(timestamp: now.addingTimeInterval(-60), credentialId: "quota", fieldName: "api-key",
                subjectFingerprint: cron.fingerprint, subjectDisplayName: cron.displayName, mode: .enforced,
                decision: "prompt_required", requestID: "req-cron"))
        }

        final class Box { var widths: [CGFloat] = [] }
        let box = Box()
        let page = AccessLogPage(credentials: credentials, access: AccessLogApprovalState(store: store),
                                 loadEdits: { [] }, selectsFirstRecord: select)
            .frame(width: width, height: 560)
            .environment(\.panelLayout, .embedded)
            .environment(\.locale, AppL10n.locale(preference: language))
            .onPreferenceChange(ActivityLineNameWidths.self) { widths in box.widths = widths }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: page)
        window.contentView = view
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return box.widths
    }
}
