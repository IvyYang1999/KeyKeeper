import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class AccessLogApprovalStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func event() -> ServiceAuditEvent {
        ServiceAuditEvent(timestamp: now.addingTimeInterval(-60), credentialId: "fixture", fieldName: "key",
                          subjectFingerprint: "app:fixture", subjectDisplayName: "Fixture App",
                          mode: .enforced, decision: "prompt_required")
    }

    private func approval(duration: ApprovalDuration = .always) -> Approval {
        Approval(subject: .init(fingerprint: "app:fixture", displayName: "Renamed App"),
                 target: .credential(id: "fixture", fields: ["key"]), duration: duration, createdAt: now)
    }

    private func group() -> AccessLogGroup {
        AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: [event()]))[0]
    }

    /// 【曾经的 bug】批准改变的是当前授权，不应擦除过去的请求次数、日期或决策。
    func test批准后状态更新但请求历史保持不变() throws {
        let store = ApprovalStore.inMemory()
        try store.recordAudit(event())
        try store.recordAudit(event())
        let state = AccessLogApprovalState(store: store)
        state.refresh(now: now)
        let original = try XCTUnwrap(state.groups.first)
        XCTAssertEqual(state.status(for: original), .notApproved)
        try store.add(approval())
        state.refresh(now: now)
        XCTAssertEqual(state.groups, [original])
        XCTAssertEqual(state.status(for: original), .approved)
        XCTAssertEqual(state.groups.first?.count, 2)
        XCTAssertEqual(try store.auditEvents(), [event(), event()])
        try store.revokeAll(forCredential: "fixture")
        state.refresh(now: now)
        XCTAssertEqual(state.status(for: original), .notApproved)
        XCTAssertEqual(state.groups, [original])
    }

    func test匹配必须包含身份目标字段且不使用显示名() {
        let row = group()
        let valid = approval()
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [valid], now: now), .approved)
        var other = valid
        other.subject.fingerprint = "app:other"
        other.subject.displayName = row.who
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [other], now: now), .notApproved)
        other = valid; other.target = .credential(id: "other", fields: ["key"])
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [other], now: now), .notApproved)
        other = valid; other.target = .credential(id: "fixture", fields: ["other"])
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [other], now: now), .notApproved)
        other = valid; other.target = .session(id: "fixture")
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [other], now: now), .notApproved)
        other = valid; other.target = .credential(id: "fixture", fields: nil)
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [other], now: now), .approved)
    }

    func test过期已消费字段进程退出和别的终端会话不能显示当前授权() {
        let row = group()
        func status(_ approval: Approval, alive: Bool = true) -> AccessLogApprovalStatus {
            .current(for: row, approvals: [approval], now: now, processAlive: { _, _ in alive })
        }
        XCTAssertEqual(status(approval(duration: .timed(now))), .notApproved)
        XCTAssertEqual(status(approval(duration: .timed(now.addingTimeInterval(1)))), .approved)
        XCTAssertEqual(status(approval(duration: .terminalSession("another-session"))), .notApproved)
        let process = approval(duration: .process(pid: 123, startedAt: now))
        XCTAssertEqual(status(process, alive: false), .notApproved)
        XCTAssertEqual(status(process), .approved)
        var once = approval(duration: .once)
        once.onceFieldsRemaining = ["other"]
        XCTAssertEqual(status(once), .notApproved)
        once.onceFieldsRemaining = ["key"]
        XCTAssertEqual(status(once), .approved)
        once.createdAt = now.addingTimeInterval(-Approval.onceWindow)
        XCTAssertEqual(status(once), .notApproved)
        once.createdAt = now; once.consumed = true
        XCTAssertEqual(status(once), .notApproved)
    }

    func test读取失败保留历史但清掉可操作状态() throws {
        let io = FakeKeychainIO()
        let store = ApprovalStore(io: io)
        try store.recordAudit(event())
        try store.add(approval())
        let state = AccessLogApprovalState(store: store)
        state.refresh(now: now)
        let original = state.groups
        let writes = io.writes
        io.failReads = true
        state.refresh(now: now)
        XCTAssertEqual(state.groups, original)
        XCTAssertEqual(state.status(for: try XCTUnwrap(original.first)), .unavailable)
        XCTAssertNotNil(state.errorMessage)
        XCTAssertEqual(io.writes, writes)
        io.failReads = false
        state.refresh(now: now)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.status(for: try XCTUnwrap(original.first)), .approved)
    }

    /// 真实生产 View + 合成 ApprovalStore：通知必须经过页面的生命周期接线。
    /// 当前 XCTest 的离屏 SwiftUI 窗口不生成 AX children；按钮/文案另经隔离 App CUA 验收。
    func test真实页面收到批准通知立即更新状态且保留历史() throws {
        _ = NSApplication.shared
        let store = ApprovalStore.inMemory()
        try store.recordAudit(event())
        let state = AccessLogApprovalState(store: store)
        let page = AccessLogPage(credentials: [], access: state, loadEdits: { [] })
        let hosting = NSHostingView(rootView: page)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 720, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        settle(hosting)
        let original = try XCTUnwrap(state.groups.first)
        XCTAssertEqual(state.status(for: original), .notApproved)
        try store.add(approval())
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        settle(hosting)
        XCTAssertEqual(state.status(for: original), .approved)
        XCTAssertEqual(state.groups, [original])
        try store.revokeAll(forCredential: "fixture")
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        settle(hosting)
        XCTAssertEqual(state.status(for: original), .notApproved)
        XCTAssertEqual(state.groups.first?.kind, .approvalRequired)
    }

    private func settle(_ view: NSView) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        view.layoutSubtreeIfNeeded()
    }

    func test自动刷新只在活动可见页面运行且错误后停止重试() {
        _ = NSApplication.shared
        let observer = AccessLogRefreshView()
        observer.interval = 0.025
        var count = 0
        var active = true
        var canRetry = true
        observer.onRefresh = { count += 1 }
        observer.isAppActive = { active }
        observer.canAutoRefresh = { canRetry }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = observer
        window.orderBack(nil)
        defer { observer.stop(); window.close() }
        settle(observer)
        XCTAssertGreaterThan(count, 0)
        active = false
        var before = count
        settle(observer)
        XCTAssertEqual(count, before, "后台不持续读钥匙串")
        active = true; canRetry = false
        settle(observer)
        XCTAssertEqual(count, before, "读失败不能自动循环重试")
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        XCTAssertEqual(count, before + 1, "明确变更通知可触发一次重新读取")
        canRetry = true
        window.orderOut(nil)
        before = count
        settle(observer)
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        XCTAssertEqual(count, before, "关闭/隐藏窗口后通知和计时器均不读取")
        window.orderBack(nil)
        settle(observer)
        XCTAssertGreaterThan(count, before)
        window.contentView = NSView()
        before = count
        settle(observer)
        NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        XCTAssertEqual(count, before, "页面移除后应撤销订阅和计时器")
    }
}
