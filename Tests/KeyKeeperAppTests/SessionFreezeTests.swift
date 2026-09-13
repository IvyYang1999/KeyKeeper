import XCTest
import WebKit
@testable import KeyKeeperApp

/// 【独立审计 2026-09-13】冻结时才去编译断网规则（异步），遮罩却立刻说「页面连不上网络」——编译完成前
/// 那段时间这句话是假的，编码失败时还会悄悄什么都不做。规则要在页面加载前编好，冻结时同步挂上。
@MainActor
final class SessionFreezeTests: XCTestCase {
    func test冻结时不再现场编译断网规则() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let runtime = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/SessionBrowserRuntime.swift"), encoding: .utf8)
        let start = try XCTUnwrap(runtime.range(of: "private func freeze()"))
        let rest = runtime[start.upperBound...]
        let body = rest[..<(rest.range(of: "\n    private func ")?.lowerBound ?? rest.endIndex)]
        XCTAssertFalse(body.contains("compileContentRuleList"), "冻结时现场编译，遮罩会先于断网出现")
        XCTAssertTrue(body.contains("add(freezeList)"))
    }

    /// 断网规则得真的编得出来——编不出来，登录态窗口就不会打开（宁可不开，也不假装能冻结）。
    func test断网规则能编译() {
        let done = expectation(description: "compiled")
        let id = "keykeeper-test-" + UUID().uuidString
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id,
                                                               encodedContentRuleList: SessionFreezeRules.encoded) { list, error in
            XCTAssertNotNil(list, String(describing: error))
            WKContentRuleListStore.default().removeContentRuleList(forIdentifier: id) { _ in }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
    }
}
