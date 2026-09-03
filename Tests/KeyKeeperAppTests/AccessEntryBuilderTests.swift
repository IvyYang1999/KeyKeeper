import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AccessEntryBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func test两种授权合并成一张表并按最近活动排序() {
        let older = Grant(id: "g1", credentialId: "c", sessionId: "w0t1p0:AAAA", duration: .session("w0t1p0:AAAA"), createdAt: now.addingTimeInterval(-3600))
        let newer = ServiceGrant(id: "s1", credentialId: "c", subjectFingerprint: "fp", subjectDisplayName: "cron quota-board", fields: ["token"], duration: .always, createdAt: now.addingTimeInterval(-7200), lastUsedAt: now.addingTimeInterval(-60))

        let entries = AccessEntryBuilder.entries(grants: [older], serviceGrants: [newer], now: now)

        XCTAssertEqual(entries.map(\.id), ["service:s1", "grant:g1"])
        XCTAssertEqual(entries[0].who, "cron quota-board")
        XCTAssertEqual(entries[0].kind, .backgroundCaller)
        XCTAssertTrue(entries[0].scope.hasPrefix("Always"))
        XCTAssertTrue(entries[0].activity.hasPrefix("Used"))
        XCTAssertEqual(entries[1].who, "Terminal session w0t1p0:A")
        XCTAssertEqual(entries[1].kind, .terminalSession)
    }

    func test过期与已消费的授权不再标为活跃() {
        let expired = Grant(id: "g", credentialId: "c", duration: .timed(now.addingTimeInterval(-1)))
        let consumed = Grant(id: "g2", credentialId: "c", duration: .once, consumed: true)
        let expiredService = ServiceGrant(id: "s", credentialId: "c", subjectFingerprint: "f", subjectDisplayName: "x", fields: [], duration: .timed(now.addingTimeInterval(-1)))

        let entries = AccessEntryBuilder.entries(grants: [expired, consumed], serviceGrants: [expiredService], now: now)
        XCTAssertTrue(entries.allSatisfy { !$0.isActive })
        XCTAssertEqual(AccessEntryBuilder.scopeLabel(expired.duration, now: now), "Expired")
    }

    func test没有会话ID的授权显示AnyTerminal() {
        let grant = Grant(id: "g", credentialId: "c", sessionId: nil, duration: .always)
        XCTAssertEqual(AccessEntryBuilder.sessionLabel(grant), "Any terminal")
    }
}
