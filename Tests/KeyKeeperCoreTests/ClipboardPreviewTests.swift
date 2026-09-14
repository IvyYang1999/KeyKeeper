import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-14：「我明明已经复制了，AI 却说要它先发起、我再复制才有效……初衷是避免复制错，
/// 结果体验很差」。改成：剪贴板上有什么就存什么，靠窗口里的遮罩预览和复制时间让人认出对不对。
final class ClipboardPreviewTests: XCTestCase {
    func test长值只露头四尾三和长度() {
        let preview = ClipboardPreview.masked("sk-ant-api03-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789xyz")
        XCTAssertEqual(preview.head, "sk-a")
        XCTAssertEqual(preview.tail, "xyz")
        XCTAssertEqual(preview.shape.characters, 52)
        XCTAssertEqual(preview.masked, "sk-a…xyz")
    }

    func test短值不露任何字符() {
        let preview = ClipboardPreview.masked("hunter2pass")
        XCTAssertEqual(preview.head, "")
        XCTAssertEqual(preview.tail, "")
        XCTAssertEqual(preview.masked, "…")
        XCTAssertEqual(preview.shape.characters, 11)
    }

    func test多行和空格能被看出来_头尾不含换行() {
        let preview = ClipboardPreview.masked("\n  a paragraph that was copied by accident, with spaces\n")
        XCTAssertTrue(preview.shape.hasWhitespace)
        XCTAssertEqual(preview.shape.lines, 3)
        XCTAssertFalse(preview.head.contains("\n") || preview.head.hasPrefix(" "))
        XCTAssertEqual(preview.head, "a pa")
    }

    func test头尾不会重叠_也不会连起来还原整个值() {
        let preview = ClipboardPreview.masked("exactly12chr")
        XCTAssertEqual(preview.head.count + preview.tail.count, 7)
        XCTAssertLessThan(preview.head.count + preview.tail.count, preview.shape.characters / 2 + 2)
    }
}
