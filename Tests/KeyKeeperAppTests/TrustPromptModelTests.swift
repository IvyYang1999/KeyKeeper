import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class TrustPromptModelTests: XCTestCase {
    func testReplacementClearlyNamesOverwriteAndPreservedPermissions() {
        let info = ClipboardSaveController.Presentation(request: .init(credentialId: "fixture", fieldName: "key",
            expect: "base64:32", replaceExisting: true), callerName: "Test")
        let model = TrustPromptModel.save(info)
        XCTAssertEqual(model.confirmTitle, "Replace value")
        XCTAssertEqual(model.tone, .caution)
        XCTAssertTrue(model.rows[0].note!.contains("Replace"))
        XCTAssertFalse(model.assurance.contains("nothing is overwritten"))
        XCTAssertTrue(model.details.contains { $0.contains("Existing permissions") })
    }
    private func presentation(file: String? = nil, symbol: String? = nil, browser: Bool = false,
                              create: Bool = true, caller: String = "claude",
                              useCurrentClipboard: Bool = false) -> ClipboardSaveController.Presentation {
        .init(request: .init(credentialId: "openai", fieldName: "api-key", create: create,
                             useCurrentClipboard: useCurrentClipboard),
              callerName: caller, fromBrowser: browser, filePath: file, pythonSymbol: symbol,
              expiresAt: Date(timeIntervalSince1970: 100))
    }

    func test三行信息卡依次是存为来源请求方() {
        let model = TrustPromptModel.save(presentation())
        XCTAssertEqual(model.rows.map(\.value), ["openai · api-key", "Clipboard", "claude"])
        XCTAssertEqual(model.title, "Save what is on the clipboard?")
        // 旧脚本还会传这个开关；现在它什么也不改。
        let current = TrustPromptModel.save(presentation(useCurrentClipboard: true))
        XCTAssertEqual(current.rows.map(\.value), model.rows.map(\.value))
        XCTAssertEqual(model.rows[0].note, "New, Ask every time")
        XCTAssertEqual(model.confirmTitle, "Save")
        XCTAssertEqual(model.expiresAt, Date(timeIntervalSince1970: 100))
    }

    /// 认对认错靠这一行：头尾几个字符、长度、是不是多行——不是靠「什么时候复制的」那套规矩。
    func test剪贴板预览一行_写清复制时间和样子() {
        var info = presentation()
        var preview = ClipboardPreview.masked("sk-live-0123456789abcdefghijklmnopqrstuvwxyz")
        preview.copiedAt = Date(timeIntervalSince1970: 90)
        info.preview = preview
        let model = TrustPromptModel.save(info, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(model.rows[1].value, "Clipboard · copied 10 s ago")
        let looks = model.rows.first { $0.label == "Looks like" }!
        XCTAssertEqual(looks.value, "sk-l…xyz · 44 characters")
        XCTAssertFalse(model.rows.contains { $0.value.contains("0123456789") })

        var prose = ClipboardPreview.masked("Sure! Here is the key you asked for:\nsk-live-123")
        prose.copiedAt = nil
        info.preview = prose
        let suspicious = TrustPromptModel.save(info, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(suspicious.rows[1].value, "Clipboard · copied before KeyKeeper started")
        XCTAssertTrue(suspicious.rows.first { $0.label == "Looks like" }!.value.contains("2 lines"))
        XCTAssertEqual(suspicious.tone, .caution, "多行、带空格的东西八成不是 key")
        XCTAssertEqual(TrustPromptModel.copiedAgo(Date(timeIntervalSince1970: 100), now: Date(timeIntervalSince1970: 102)), "just now")
        XCTAssertEqual(TrustPromptModel.copiedAgo(Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 200)), "3 min ago")
    }

    /// 剪贴板在窗口开着时变了：换的是别的进程也说不定。按钮重新走一遍冷静期，正落下的点击别打在换过的内容上。
    @MainActor func test剪贴板一变_确认按钮重新走冷静期() {
        let presenter = TrustPromptPresenter(center: ApprovalCenter())
        var info = presentation()
        info.preview = ClipboardPreview.masked("first-value-on-the-clipboard")
        presenter.show(.save(info), symbol: "doc.on.clipboard", decide: { _ in })
        defer { presenter.dismiss() }
        XCTAssertEqual(presenter.installedModel?.settleToken, 0)
        info.preview = ClipboardPreview.masked("second-value-on-the-clipboard")
        presenter.update(.save(info))
        XCTAssertEqual(presenter.installedModel?.settleToken, 1)
        presenter.update(.save(info))
        XCTAssertEqual(presenter.installedModel?.settleToken, 2)
        let view = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/KeyKeeperApp/TrustPrompt.swift"), encoding: .utf8)
        XCTAssertTrue(view?.contains(".onChange(of: model.settleToken)") == true, "视图要在 token 变化时重置 canConfirm")
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
