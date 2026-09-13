import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class ExpiryCopyTests: XCTestCase {
    func test过期相关文案有中文() {
        for template in ["Use a date like 2026-12-31, or never to clear it.", "Expires {0}", "Expiry date cleared"] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }

    func test给Agent的提示词带上过期日() {
        var credential = Credential(label: "A", notes: "", links: [], fields: ["api-key": .init(secret: true)],
                                    security: .standard, created: "2026-01-01", updated: "2026-01-01")
        XCTAssertFalse(AgentPromptCopy.prompt(credentialId: "a", credential: credential, language: "en").contains("expiring"))
        credential.expires = "2026-12-31"
        XCTAssertTrue(AgentPromptCopy.prompt(credentialId: "a", credential: credential, language: "en").contains("2026-12-31"))
        XCTAssertTrue(AgentPromptCopy.prompt(credentialId: "a", credential: credential, language: "zh-Hans").contains("2026-12-31"))
    }
}
