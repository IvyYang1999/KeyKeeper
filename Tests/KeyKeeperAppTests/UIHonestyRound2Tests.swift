import XCTest
@testable import KeyKeeperApp

/// 独立审计第二轮里界面层的几处，行为测试够不着的用源码结构钉住。
@MainActor
final class UIHonestyRound2Tests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 已有登录态快照时，页面上关于 Chrome 只剩这一行；被改过或挪过位置时它得带着修复按钮。
    func test状态行带重新登记按钮() throws {
        let views = try source("Sources/KeyKeeperApp/BrowserSessionViews.swift")
        let start = try XCTUnwrap(views.range(of: "struct BrowserExtensionStatusLine"))
        let rest = views[start.upperBound...]
        let body = rest[..<(rest.range(of: "\nstruct ")?.lowerBound ?? rest.endIndex)]
        XCTAssertTrue(body.contains("Button(L(\"Register again\"))"))
        XCTAssertTrue(BrowserExtensionSetup.registrationReplacesExisting(.moved))
    }

    func test调用方能改的名字都走强过滤() throws {
        XCTAssertTrue(try source("Sources/KeyKeeperApp/AppDelegate.swift").contains("printableLine(request.credentialLabel"))
        XCTAssertTrue(try source("Sources/KeyKeeperApp/TrustPrompt.swift").contains("printableLine(info.session.label"))
        XCTAssertTrue(try source("Sources/KeyKeeperApp/BrowserSessionViews.swift").contains("printableLine(item.label"))
    }

    /// ⌘↩ 是聊天和评论框的「发送」，而确认框会抢焦点。
    func test确认框没有快捷键() throws {
        XCTAssertFalse(try source("Sources/KeyKeeperApp/TrustPrompt.swift").contains("modifiers: .command"))
    }

    func test新文案有中文() {
        for key in ["KeyKeeper has moved since Chrome was connected",
                    "The registration still points at KeyKeeper's old location. Register again to point it here."] {
            XCTAssertNotNil(AppL10n.chinese[key], key)
        }
    }
}
