import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 建议只能靠人批准这个窗才生效，所以窗里必须写出来、写明是谁建议的。
@MainActor
final class SaveSuggestionPromptTests: XCTestCase {
    private func model(_ request: ClipboardSaveRequest) -> TrustPromptModel {
        TrustPromptModel.save(.init(request: request, callerName: "codex"))
    }

    func test保存窗写出Agent建议的保护方式和过期日() {
        let prompt = model(.init(credentialId: "a", fieldName: "k", create: true, security: .standard, expires: "2026-12-31"))
        XCTAssertEqual(prompt.rows.prefix(3).map(\.label), [L("Save as"), L("Source"), L("Requested by")], "原来的三行不动")
        XCTAssertEqual(prompt.rows.first?.note, L("New, Background OK"))
        let protection = prompt.rows.first { $0.label == L("Protection") }
        XCTAssertEqual(protection?.value, SecurityLevelPresentation.badge(.standard))
        XCTAssertTrue(protection?.note?.contains("codex") == true)
        XCTAssertEqual(prompt.rows.first { $0.label == L("Expires") }?.value, "2026-12-31")
        XCTAssertEqual(prompt.tone, .caution, "放宽到后台可用，要让人多看一眼")
    }

    func test没有建议时照旧三行且每次询问() {
        let prompt = model(.init(credentialId: "a", fieldName: "k", create: true))
        XCTAssertEqual(prompt.rows.count, 3, "没有建议就还是那三行")
        XCTAssertEqual(prompt.rows.first?.note, L("New, Ask every time"))
        XCTAssertNil(prompt.rows.first { $0.label == L("Protection") })
        XCTAssertNil(prompt.rows.first { $0.label == L("Expires") })
        XCTAssertEqual(prompt.tone, .reassuring)
    }

    func test新文案有中文() {
        for template in ["New, Background OK", "Protection", "Suggested by {0}", "Expires",
                         "Create a new credential that background callers can use after you approve each one once, as {0} suggested."] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }
}
