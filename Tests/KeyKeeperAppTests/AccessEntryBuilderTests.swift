import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AccessEntryBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let cron = ApprovalSubject(fingerprint: "unsigned:path=cron", displayName: "cron quota-board")

    func test各种授权合成一张表并按最近活动排序() {
        let older = Approval(id: "g1", subject: cron, target: .credential(id: "c", fields: nil),
                             duration: .terminalSession("w0t1p0:AAAA"), createdAt: now.addingTimeInterval(-3600))
        let newer = Approval(id: "s1", subject: cron, target: .credential(id: "c", fields: ["token"]), duration: .always,
                             createdAt: now.addingTimeInterval(-7200), lastUsedAt: now.addingTimeInterval(-60))
        let login = Approval(id: "l1", subject: cron, target: .session(id: "sess"), duration: .always, createdAt: now.addingTimeInterval(-10))

        let entries = AccessEntryBuilder.entries(approvals: [older, newer, login], now: now)

        XCTAssertEqual(entries.map(\.id), ["approval:l1", "approval:s1", "approval:g1"])
        XCTAssertEqual(entries[0].kind, .websiteLogin)
        XCTAssertEqual(entries[1].who, "cron quota-board")
        XCTAssertEqual(entries[1].kind, .backgroundCaller)
        XCTAssertTrue(entries[1].scope.hasPrefix("Always"))
        XCTAssertTrue(entries[1].scope.contains("token"))
        XCTAssertTrue(entries[1].activity.hasPrefix("Used"))
        XCTAssertEqual(entries[2].who, "cron quota-board · Terminal session w0t1p0:A")
        XCTAssertEqual(entries[2].kind, .terminalSession)
    }

    func test过期与已消费的授权不再标为活跃() {
        let expired = Approval(id: "g", subject: cron, target: .credential(id: "c", fields: nil), duration: .timed(now.addingTimeInterval(-1)))
        let consumed = Approval(id: "g2", subject: cron, target: .credential(id: "c", fields: nil), duration: .once, consumed: true)
        let entries = AccessEntryBuilder.entries(approvals: [expired, consumed], now: now)
        XCTAssertTrue(entries.allSatisfy { !$0.isActive })
        XCTAssertEqual(AccessEntryBuilder.scopeLabel(expired, now: now), "Expired")
    }
}
