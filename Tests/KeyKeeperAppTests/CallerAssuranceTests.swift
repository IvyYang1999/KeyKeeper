import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【安全审计 2026-09-13】弹窗上「谁在请求」那一栏，默认视图里不给任何签名证据——一个
/// 未签名的本地程序和一个 Developer ID 签名的 App 看起来一模一样。而今天身份改成三档
/// 之后，这个差别恰恰是用户该看见的。
final class CallerAssuranceTests: XCTestCase {
    private func subject(_ fingerprint: String) -> CallerSubject {
        CallerSubject(kind: .app, fingerprint: fingerprint, displayName: "Agent", detail: "")
    }

    func test三档各自的说法() {
        XCTAssertEqual(CallerAssurance.of(subject("app:team=ABCDE12345:bundle=com.example.a:signing=x")), .signed)
        XCTAssertEqual(CallerAssurance.of(subject("unsigned:path=abc123")), .unsigned)
        XCTAssertEqual(CallerAssurance.of(subject("unverified:unlocatable")), .unverified)
    }

    func test每一档都有给人看的说明() {
        for assurance in [CallerAssurance.signed, .unsigned, .unverified] {
            XCTAssertFalse(assurance.label.isEmpty, "\(assurance)")
            XCTAssertFalse(assurance.explanation.isEmpty, "\(assurance)")
        }
        // 未核实的那一档必须说清「记不住它」，否则人会以为选了「始终允许」就不再问
        XCTAssertTrue(CallerAssurance.unverified.explanation.contains("every time"),
                      CallerAssurance.unverified.explanation)
        let zh = AppL10n.render(CallerAssurance.unverified.explanation, language: "zh-Hans")
        XCTAssertNotEqual(zh, CallerAssurance.unverified.explanation, "这句必须有中文")
        XCTAssertTrue(zh.contains("每次"), zh)
    }

    /// 只有已签名的那一档该显得「安心」，另外两档不能。
    func test只有签名那一档算安心() {
        XCTAssertTrue(CallerAssurance.signed.isReassuring)
        XCTAssertFalse(CallerAssurance.unsigned.isReassuring)
        XCTAssertFalse(CallerAssurance.unverified.isReassuring)
    }
}
