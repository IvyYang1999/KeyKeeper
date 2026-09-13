import XCTest
@testable import KeyKeeperApp

/// 【安全审计 2026-09-13】授权窗把「允许」绑在无修饰的 Return 上，同时每次请求都强抢焦点。
/// 两件事叠起来就是：你正在别处敲回车，一个弹窗跳到面前，你那一下回车就把它批了。
///
/// 修法两条：允许键不再吃 Return（Esc 仍然是拒绝），以及弹窗出现后的头一小段时间里
/// 「允许」不可点——防的是「窗口刚弹出来就被一次早已排好的点击命中」。
final class ApprovalReadinessTests: XCTestCase {
    private let shown = Date(timeIntervalSince1970: 1_800_000_000)

    func test刚弹出来的那一瞬间不能批准() {
        XCTAssertFalse(ApprovalReadiness.canApprove(shownAt: shown, now: shown))
        XCTAssertFalse(ApprovalReadiness.canApprove(shownAt: shown, now: shown.addingTimeInterval(0.3)))
    }

    func test过了静默期就能批准() {
        XCTAssertTrue(ApprovalReadiness.canApprove(shownAt: shown, now: shown.addingTimeInterval(ApprovalReadiness.settleDelay)))
        XCTAssertTrue(ApprovalReadiness.canApprove(shownAt: shown, now: shown.addingTimeInterval(5)))
    }

    /// 拒绝永远可以立刻点——把人挡在「拒绝」外面没有任何道理。
    func test拒绝不受静默期限制() {
        XCTAssertTrue(ApprovalReadiness.canDeny(shownAt: shown, now: shown))
    }

    /// 静默期要短到不惹人烦，又长到挡住「窗口一出现就被命中」。
    func test静默期在合理区间() {
        XCTAssertGreaterThanOrEqual(ApprovalReadiness.settleDelay, 0.35)
        XCTAssertLessThanOrEqual(ApprovalReadiness.settleDelay, 1.0)
    }

    /// 允许键不能挂在无修饰的 Return 上。
    func test允许键不吃回车() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AuthorizationView.swift"), encoding: .utf8)
        XCTAssertFalse(source.contains(".keyboardShortcut(.return)"),
                       "别处敲的一次回车不该批准一个刚跳出来的授权窗")
        XCTAssertTrue(source.contains(".keyboardShortcut(.escape)"), "Esc 仍然要能拒绝")
    }
}
