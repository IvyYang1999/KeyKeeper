import XCTest
@testable import KeyKeeperApp

/// 【独立审计 2026-09-13】授权窗有 0.5 秒冷静期，菜单栏「等你处理」里的同一个请求却一点就批准——
/// 保存凭据、打开登录态都能从这里一次点击放行，冷静期被整个绕开。
@MainActor
final class ApprovalCenterReadinessTests: XCTestCase {
    func test菜单栏里的批准也有冷静期() {
        let shown = Date()
        let item = ApprovalCenter.Item(id: UUID(), symbol: "key", title: "t", detail: "d", expiresAt: nil,
                                       confirmTitle: "OK", destructive: false, opensWindow: false,
                                       confirm: {}, deny: {}, shownAt: shown)
        XCTAssertFalse(item.canConfirm(now: shown.addingTimeInterval(0.1)))
        XCTAssertTrue(item.canConfirm(now: shown.addingTimeInterval(ApprovalReadiness.settleDelay)))
    }

    /// 要打开完整授权窗的项不在这里等：那扇窗自己有冷静期。
    func test打开完整窗口的项不重复等待() {
        let shown = Date()
        let item = ApprovalCenter.Item(id: UUID(), symbol: "key", title: "t", detail: "d", expiresAt: nil,
                                       confirmTitle: "OK", destructive: false, opensWindow: true,
                                       confirm: {}, deny: {}, shownAt: shown)
        XCTAssertTrue(item.canConfirm(now: shown))
    }
}
