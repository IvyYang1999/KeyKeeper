import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

@MainActor final class ActivityNavigationTests: XCTestCase {
    private func grant(_ id: String, subject: String = "app:first", credential: String = "fixture") -> Approval {
        Approval(id: id, subject: .init(fingerprint: subject, displayName: "Same App"),
                 target: .credential(id: credential, fields: nil), duration: .always)
    }

    func test权限按身份分组而非显示名且未知身份独立() {
        let groups = PermissionGroup.build([grant("1"), grant("2", credential: "other"),
            grant("3", subject: "app:second"), grant("4", subject: ""), grant("5", subject: ""),
            grant("6", subject: CallerSubject.unverifiedPrefix + "test"), grant("7", subject: CallerSubject.unverifiedPrefix + "test")])
        XCTAssertEqual(groups.count, 6)
        XCTAssertEqual(groups.first { $0.id == "app:first" }?.approvals.count, 2)
    }

    func test只撤销选中的授权不影响同名调用方或其他凭据() throws {
        let io = FakeKeychainIO()
        let store = ApprovalStore(io: io)
        let first = grant("1")
        try store.add(first)
        try store.add(grant("2", credential: "other"))
        try store.add(grant("3", subject: "app:second"))
        let state = PermissionPageState(store: store)
        let writes = io.writes
        state.refresh()
        XCTAssertEqual(io.writes, writes, "浏览权限详情不能写存储")
        state.revoke(first)
        XCTAssertEqual(Set(try store.all().map(\.id)), ["2", "3"])
        XCTAssertNil(state.errorMessage)
    }

    func test旧详情不能撤销被替换为其他对象的同ID授权() throws {
        let store = ApprovalStore.inMemory()
        let first = grant("1")
        let state = PermissionPageState(store: store)
        try store.add(grant("1", subject: "app:second"))
        state.revoke(first)
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertNotNil(state.errorMessage)
    }

    func test读失败保留列表但不误报有效() throws {
        let io = FakeKeychainIO()
        let store = ApprovalStore(io: io)
        try store.add(grant("1"))
        let state = PermissionPageState(store: store)
        state.refresh()
        io.failReads = true
        state.refresh()
        XCTAssertEqual(state.approvals.count, 1)
        XCTAssertFalse(state.available)
        XCTAssertNotNil(state.errorMessage)
    }

    func test合并行保留真实事件供下钻但不伪造逐次读取历史() {
        let events = (0..<3).map { i in
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: Double(i)), credentialId: "fixture", fieldName: "key",
                subjectFingerprint: "app:fixture", subjectDisplayName: "Fixture", mode: .enforced, decision: "prompt_required")
        }
        let groups = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: events))
        XCTAssertEqual(groups[0].entries.count, 3)
        XCTAssertEqual(groups[0].entries.map(\.date), events.reversed().map(\.timestamp))
    }

    func test详情仅展示命令摘要并遮盖常见秘密参数() {
        // Fresh random fixture, never an actual credential or an executed command.
        let sample = UUID().uuidString
        let raw = ["tool", "--api-key", sample, "--password", "'" + sample + " value'",
                   "TOKEN" + "=" + sample, "--header", "\"Authorization: Bearer " + sample + "\""].joined(separator: " ")
        let rendered = ActivityDetailCopy.command(raw)
        XCTAssertFalse(rendered.contains(sample))
        XCTAssertTrue(rendered.contains("[REDACTED]"))
        XCTAssertEqual(ActivityDetailCopy.command(nil), L("Not recorded"))
    }

    func test访问默认标签以及窄屏布局() {
        XCTAssertEqual(ActivityTab.defaultTab, .access)
        XCTAssertFalse(ActivityDetailLayoutPolicy.isSplit(width: 680))
        XCTAssertTrue(ActivityDetailLayoutPolicy.isSplit(width: 1100))
    }

    func test切换标签不能沿用另一个记录类型的滚动容器() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/ActivityPage.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(".id(tab)"))
        XCTAssertFalse(source.contains("tab == .access ? accessPosition : changesPosition"))
    }

    func test访问详情不能把多字段权限当成一个拼接字段() throws {
        let now = Date()
        var multi = grant("multi")
        multi.target = .credential(id: "fixture", fields: ["key", "other"])
        multi.lastUsedAt = now
        let row = try XCTUnwrap(AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [multi], auditEvents: [])).first)
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [multi], now: now), .approved)
        var subset = multi
        subset.target = .credential(id: "fixture", fields: ["key"])
        XCTAssertEqual(AccessLogApprovalStatus.current(for: row, approvals: [subset], now: now), .notApproved)
        var all = grant("all"); all.lastUsedAt = now
        let allRow = try XCTUnwrap(AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [all], auditEvents: [])).first)
        XCTAssertEqual(AccessLogApprovalStatus.current(for: allRow, approvals: [all], now: now), .approved)
        XCTAssertEqual(AccessLogApprovalStatus.current(for: allRow, approvals: [multi], now: now), .notApproved)
        var comma = multi
        comma.id = "comma"; comma.target = .credential(id: "fixture", fields: ["key, other"])
        XCTAssertEqual(AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [multi, comma], auditEvents: [])).count, 2)
    }
}
