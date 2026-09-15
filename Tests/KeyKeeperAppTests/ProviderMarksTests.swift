import XCTest
import AppKit
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-15：服务商和调用方要有 logo，一眼认出，别全是小字。
@MainActor
final class ProviderMarksTests: XCTestCase {
    func test每个服务商都有主题色_官方标能渲染_其余明确退回字母标() {
        let catalogIds = Set(ProviderCatalog.all.map(\.id))
        XCTAssertEqual(Set(ProviderMarks.brandHexes.keys), catalogIds)
        XCTAssertEqual(Set(ProviderMarks.sourceURLs.keys), catalogIds)

        for template in ProviderCatalog.all {
            XCTAssertNotNil(ProviderMarks.brandColor(for: template.id), template.id)
            XCTAssertTrue(ProviderMarks.sourceURLs[template.id]?.hasPrefix("https://") == true, template.id)
            if let image = ProviderMarks.image(for: template.id) {
                XCTAssertTrue(image.isTemplate, template.id)
                XCTAssertGreaterThan(image.size.width, 0, template.id)
                XCTAssertTrue(ProviderMarks.marks[template.id]?.source.hasPrefix("https://") == true, template.id)
            } else {
                XCTAssertFalse(ProviderMarks.letter(for: template.id).isEmpty, template.id)
            }
        }

        let lettermarkIds = catalogIds.subtracting(ProviderMarks.marks.keys)
        XCTAssertEqual(lettermarkIds, [
            "openai", "groq", "zhipu", "volcengine-ark", "aws", "azure",
            "twilio", "sendgrid", "slack", "feishu",
        ])

        XCTAssertNotNil(ProviderMarks.image(for: "stripe"))
        XCTAssertNotNil(ProviderMarks.image(for: "github"))
        XCTAssertNotNil(ProviderMarks.image(for: "gemini"))
        XCTAssertNotNil(ProviderMarks.image(for: "anthropic"))
        XCTAssertNotNil(ProviderMarks.image(for: "siliconflow"))
        // No locally bundled, provider-sourced vector asset yet: use a coloured letter, never a
        // made-up generic product icon or an untraceable favicon.
        XCTAssertNil(ProviderMarks.image(for: "openai"))
        XCTAssertEqual(ProviderMarks.letter(for: "openai"), "O")
        XCTAssertNotNil(ProviderMarks.brandColor(for: "openai"))
        XCTAssertNil(ProviderMarks.image(for: "nope"))
        XCTAssertNil(ProviderMarks.brandColor(for: "nope"))
    }

    func test命令行Agent映射到桌面App的图标_没装就字母标() {
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "com.anthropic.claude-code").first, "com.anthropic.claudefordesktop")
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "com.openai.codex"), ["com.openai.codex", "com.openai.codex"])
        XCTAssertEqual(CallerAppIcon.desktopBundleIds(for: "python3"), ["python3"])
        XCTAssertNil(CallerAppIcon.image(for: "com.example.not-installed-\(UUID().uuidString)"))
    }

    func test保存弹窗的服务商行带上图标() {
        let request = ClipboardSaveRequest(credentialId: "stripe", fieldName: "stripe-api-key", create: true, provider: "stripe")
        let model = TrustPromptModel.save(.init(request: request, callerName: "com.openai.codex"))
        let provider = model.rows.first { $0.label == "Provider" }!
        XCTAssertEqual(provider.icon, .provider("stripe"))
        XCTAssertEqual(model.rows.first { $0.label == "Requested by" }?.icon, .caller("com.openai.codex"))
    }
}
