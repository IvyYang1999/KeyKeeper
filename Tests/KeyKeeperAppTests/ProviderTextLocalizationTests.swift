import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-08 主力 Mac 验收 follow-up：服务商的有效期、最小权限说明一半英文一半中文，
/// 哪种界面语言都会冒出另一种语言。现在每一条都要有另一种语言的译文。
final class ProviderTextLocalizationTests: XCTestCase {
    private var shownTexts: Set<String> {
        Set(ProviderCatalog.all.flatMap { [$0.expiryNote, $0.minimalPermission].compactMap { $0 } })
    }

    func test曾经的Bug服务商说明在两种界面语言下都是那种语言() throws {
        let chinese = { (text: String) in text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        var missing: [String] = []
        for text in shownTexts.sorted() {
            if chinese(text) {
                if !chinese(ProviderText.localized(text, language: "en")) { continue }
                missing.append("EN<-ZH\t" + text)
            } else {
                if chinese(ProviderText.localized(text, language: "zh-Hans")) { continue }
                missing.append("ZH<-EN\t" + text)
            }
        }
        if let path = ProcessInfo.processInfo.environment["KEYKEEPER_PROVIDER_TEXT_DUMP"] {
            try missing.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(missing.count, 0, "缺译文 \(missing.count) 条：\n" + missing.prefix(5).joined(separator: "\n"))
    }

    func test同语言原样返回且不认识的原样返回() {
        XCTAssertEqual(ProviderText.localized("API keys remain valid until revoked.", language: "en"), "API keys remain valid until revoked.")
        XCTAssertEqual(ProviderText.localized("没见过的中文", language: "zh-Hans"), "没见过的中文")
        XCTAssertEqual(ProviderText.localized("Never seen before", language: "zh-Hans"), "Never seen before")
    }
}
