import XCTest
import AppKit
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-15：服务商和调用方要有 logo，一眼认出，别全是小字。
@MainActor
final class ProviderMarksTests: XCTestCase {
    func test有官方标的六家能渲染成模板图_其余退回字母标() {
        for template in ProviderCatalog.all {
            if let image = ProviderMarks.image(for: template.id) {
                XCTAssertTrue(image.isTemplate, template.id)
                XCTAssertGreaterThan(image.size.width, 0, template.id)
                XCTAssertNotNil(ProviderMarks.brandColor(for: template.id), template.id)
            } else {
                XCTAssertFalse(ProviderMarks.letter(for: template.id).isEmpty, template.id)
            }
        }
        XCTAssertNotNil(ProviderMarks.image(for: "stripe"))
        XCTAssertNotNil(ProviderMarks.image(for: "github"))
        // Brand rules: no OpenAI / Google / Anthropic logo in third-party UI; lettermarks instead.
        XCTAssertNil(ProviderMarks.image(for: "openai"))
        XCTAssertNil(ProviderMarks.image(for: "gemini"))
        XCTAssertNil(ProviderMarks.image(for: "anthropic"))
        XCTAssertEqual(ProviderMarks.letter(for: "openai"), "O")
        XCTAssertEqual(ProviderMarks.letter(for: "gemini"), "G")
        XCTAssertNil(ProviderMarks.image(for: "nope"))
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
