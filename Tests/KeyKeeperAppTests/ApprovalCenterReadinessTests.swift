import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【独立审计 2026-09-13】授权窗有 0.5 秒冷静期，菜单栏「等你处理」里的同一个请求却一点就批准——
/// 保存凭据、打开登录态都能从这里一次点击放行，冷静期被整个绕开。
@MainActor
final class ApprovalCenterReadinessTests: XCTestCase {
    func test授权提示音默认关闭并可由用户开启() {
        let defaults = UserDefaults(suiteName: "KeyKeeperApprovalSoundTest-\(UUID().uuidString)")!
        XCTAssertFalse(ApprovalAlertPreferences.shouldPlaySound(defaults: defaults))
        defaults.set(true, forKey: ApprovalAlertPreferences.soundKey)
        XCTAssertTrue(ApprovalAlertPreferences.shouldPlaySound(defaults: defaults))
    }

    func test已读的错过请求不会继续占据菜单面板() {
        let event = ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "siliconflow",
                                      fieldName: "api-key", subjectFingerprint: "app:agent",
                                      subjectDisplayName: "Agent", mode: .enforced,
                                      decision: "missed_approval", requestID: "request-1")
        XCTAssertEqual(ApprovalCenter.visibleMissed(events: [event], dismissed: []).count, 1)
        XCTAssertTrue(ApprovalCenter.visibleMissed(events: [event], dismissed: ["request-1"]).isEmpty)
    }

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
