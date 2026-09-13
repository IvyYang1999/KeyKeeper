import XCTest
@testable import KeyKeeperApp

/// 【独立审计 2026-09-13】授权窗对每一种调用方都说「只有它，本机别的程序蹭不到」。
/// 未签名的调用方是靠它运行的文件认的——从同一个文件启动的都算它；认不出的调用方则什么都不会记住。
@MainActor
final class ScopeLineTests: XCTestCase {
    private func render(_ t: UILocalizedString, _ language: String) -> String {
        AppL10n.render(t.template, arguments: t.arguments, language: language)
    }

    func test未签名的调用方不说只有它() {
        for whole in [true, false] {
            let en = render(CallerAssurance.unsigned.scope(caller: "node", wholeCredential: whole), "en")
            XCTAssertFalse(en.contains("not other programs"), en)
            XCTAssertTrue(en.contains("same file"), en)
            XCTAssertTrue(en.contains("node"), en)
        }
    }

    func test认不出的调用方说清不会记住() {
        let en = render(CallerAssurance.unverified.scope(caller: "?", wholeCredential: true), "en")
        XCTAssertTrue(en.contains("not remembered"), en)
    }

    func test每一种说法都有中文() {
        for tier in [CallerAssurance.signed, .unsigned, .unverified] {
            for whole in [true, false] {
                let t = tier.scope(caller: "claude", wholeCredential: whole)
                let zh = render(t, "zh-Hans")
                XCTAssertNotEqual(zh, render(t, "en"), "\(tier) \(whole)")
                XCTAssertTrue(zh.contains("claude"), zh)
                XCTAssertFalse(zh.contains("{"), zh)
            }
        }
    }
}
