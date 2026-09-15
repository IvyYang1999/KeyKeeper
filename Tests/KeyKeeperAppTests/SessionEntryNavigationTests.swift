import XCTest
@testable import KeyKeeperApp

final class SessionEntryNavigationTests: XCTestCase {
    /// 【曾经的 bug】保存第一个会话后，未登记 Chrome 的用户失去了安装入口。
    func test双入口不能仅存在于空列表分支() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/BrowserSessionViews.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains("if controller.sessions.isEmpty {\n                    BrowserSessionStartCard"))
        XCTAssertTrue(source.contains("BrowserSessionStartCard(setup: $setup"))
        XCTAssertFalse(source.contains("BrowserExtensionStatusLine(setup: $setup)"), "非空列表不能再依赖会吞掉未登记状态的旧单行入口")
    }
}
