import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-14：「这个弹窗内容其实也可以重新考虑下，有很多详细说明可以折叠的」。
/// 可见区只留事实和一句话的范围；解释性文字全部收进「详情」。
@MainActor
final class PromptCompactnessTests: XCTestCase {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AuthorizationView.swift"), encoding: .utf8)
    }

    func test解释性文字只出现在折叠区() throws {
        let view = try source()
        let details = try XCTUnwrap(view.range(of: "private var callerDetailsSection"))
        let afterDetails = view[details.upperBound...]
        for wording in ["callerAssurance.explanation", "callerAssurance.scopeLine(", "no terminal session (cron, IDE or SDK)"] {
            XCTAssertEqual(view.components(separatedBy: wording).count - 1, 1, "\(wording) 应只出现一次")
            XCTAssertTrue(afterDetails.contains(wording), "\(wording) 应在折叠区里")
        }
        XCTAssertFalse(view.contains("callerAssuranceRow") && view.contains("Text(assurance.explanation)"), "档位那一行只留标签")
    }

    func test每一档都有一句话的范围且有中文() {
        for tier in [CallerAssurance.signed, .unsigned, .unverified, .relayed] {
            let t = tier.scopeSummary(caller: "codex")
            let en = AppL10n.render(t.template, arguments: t.arguments, language: "en")
            let zh = AppL10n.render(t.template, arguments: t.arguments, language: "zh-Hans")
            XCTAssertLessThan(en.count, 80, en)
            XCTAssertNotEqual(zh, en, "\(tier)")
            XCTAssertFalse(zh.contains("{"), zh)
        }
        XCTAssertFalse(AppL10n.render(CallerAssurance.relayed.scopeSummary(caller: "x").template, language: "en").contains("only"))
    }

    func test没有终端会话时不再画来源行() throws {
        XCTAssertTrue(try source().contains("if prompt.hasTerminalSession, let sessionLabel = prompt.sessionLabel"))
    }
}
