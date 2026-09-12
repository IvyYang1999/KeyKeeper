import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class CredentialPresentationTests: XCTestCase {
    /// yyt 2026-09-11：备注里的网址应该能直接点开，而不是纯文本。
    func test备注里的网址变成可点击链接且文字不变() {
        let note = "主要用来做学术搜索。https://console.bce.baidu.com/qianfan/overview 控制台"
        let text = NoteText.attributed(note)
        XCTAssertEqual(String(text.characters), note)
        XCTAssertEqual(text.runs.compactMap(\.link), [URL(string: "https://console.bce.baidu.com/qianfan/overview")!])
        XCTAssertTrue(NoteText.attributed("没有网址").runs.compactMap(\.link).isEmpty)
    }

    /// yyt 2026-09-11：文件类的 key 要一眼看出是文件，不然会以为是 bug。
    func test按字段判断是文件还是文本() {
        func credential(_ fields: [String: CredentialField]) -> Credential {
            Credential(label: "X", notes: "", links: [], fields: fields, security: .standard, created: "2026-09-11", updated: "2026-09-11")
        }
        XCTAssertEqual(CredentialKind(credential(["api-key": .init(secret: true)])), .text)
        XCTAssertEqual(CredentialKind(credential(["credentials-json": .init(secret: true, fileFormat: .serviceAccountJSON)])), .serviceAccountFile)
    }
}
