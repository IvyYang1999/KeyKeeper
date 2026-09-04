import XCTest
@testable import KeyKeeperApp

@MainActor
final class UICommandInboxTests: XCTestCase {
    /// 【曾经的 bug】深链与状态栏 Settings 走 NotificationCenter，订阅者挂在列表页上；
    /// 只要当前不在列表页（含 popover 从未渲染过），请求就被静默丢弃，且无任何报错。
    func test曾经的Bug请求会被保留直到有人消费() throws {
        let inbox = UICommandInbox()
        XCTAssertNil(inbox.pendingAddCredential)

        let link = try XCTUnwrap(DeepLink.parse(XCTUnwrap(URL(string: "keykeeper://add?label=OpenAI&fields=api-key"))))
        inbox.requestAddCredential(link)

        // 请求一直躺在收件箱里，等任意页面渲染后取走——这正是通知做不到的。
        XCTAssertEqual(inbox.pendingAddCredential, link)
        inbox.clearAddCredential()
        XCTAssertNil(inbox.pendingAddCredential)
    }

    func test后到的深链覆盖前一个() throws {
        let inbox = UICommandInbox()
        let first = try XCTUnwrap(DeepLink.parse(XCTUnwrap(URL(string: "keykeeper://add?label=A"))))
        let second = try XCTUnwrap(DeepLink.parse(XCTUnwrap(URL(string: "keykeeper://add?label=B"))))
        inbox.requestAddCredential(first)
        inbox.requestAddCredential(second)
        XCTAssertEqual(inbox.pendingAddCredential, second)
    }

    func testSettings请求同样被保留与清除() {
        let inbox = UICommandInbox()
        XCTAssertFalse(inbox.pendingSettings)
        inbox.requestSettings()
        XCTAssertTrue(inbox.pendingSettings)
        inbox.clearSettings()
        XCTAssertFalse(inbox.pendingSettings)
    }
}
