import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class TrustPromptModelTests: XCTestCase {
    private func presentation(file: String? = nil, symbol: String? = nil, browser: Bool = false,
                              create: Bool = true, caller: String = "claude") -> ClipboardSaveController.Presentation {
        .init(request: .init(credentialId: "openai", fieldName: "api-key", create: create),
              callerName: caller, fromBrowser: browser, filePath: file, pythonSymbol: symbol,
              expiresAt: Date(timeIntervalSince1970: 100))
    }

    func test三行信息卡依次是存为来源请求方() {
        let model = TrustPromptModel.save(presentation())
        XCTAssertEqual(model.rows.map(\.value), ["openai · api-key", "Clipboard", "claude"])
        XCTAssertEqual(model.rows[0].note, "New, Ask every time")
        XCTAssertEqual(model.confirmTitle, "Save")
        XCTAssertEqual(model.expiresAt, Date(timeIntervalSince1970: 100))
    }

    func test文件只显示文件名悬停看完整路径() {
        let model = TrustPromptModel.save(presentation(file: "/Users/me/Downloads/service-account.json"))
        XCTAssertEqual(model.rows[1].value, "service-account.json")
        XCTAssertEqual(model.rows[1].help, "/Users/me/Downloads/service-account.json")
    }

    func test细则收进详细说明而不是正文() {
        let model = TrustPromptModel.save(presentation(file: "/tmp/a.json"))
        XCTAssertFalse(model.assurance.contains("64 KiB"))
        XCTAssertTrue(model.details.contains { $0.contains("64 KiB") })
    }

    func test请求方名字去掉控制字符并截断() {
        let model = TrustPromptModel.save(presentation(caller: "evil\u{1B}[2J" + String(repeating: "x", count: 200)))
        let caller = model.rows[2].value
        XCTAssertFalse(caller.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertLessThanOrEqual(caller.count, 80)
    }

    func test删除网站快照用破坏性色调() {
        let summary = BrowserSessionSummary(snapshot: .init(id: "s1", origin: "https://example.com", label: "Work", cookies: []),
                                            createdAt: Date())
        let model = TrustPromptModel.browserSession(.init(action: .delete, session: summary, caller: "claude"), expiresAt: nil)
        XCTAssertEqual(model.tone, .destructive)
        XCTAssertEqual(model.confirmTitle, "Delete")
    }

    func test新面板文案都有中文() {
        let templates = AppL10n.chineseSupplement.keys
        for template in templates {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
        XCTAssertEqual(AppL10n.render("Save what you just copied?", language: "zh-Hans"), "保存你刚复制的内容？")
    }
}
