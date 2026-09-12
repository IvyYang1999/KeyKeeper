import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AccessLogBuilderTests: XCTestCase {
    func test合并授权使用与审计事件并按时间倒序() {
        let used = ServiceGrant(credentialId: "openai", subjectFingerprint: "fp", subjectDisplayName: "claude",
                                fields: ["api-key"], duration: .always, lastUsedAt: Date(timeIntervalSince1970: 300))
        let neverUsed = ServiceGrant(credentialId: "stripe", subjectFingerprint: "fp2", subjectDisplayName: "cron",
                                     fields: ["secret-key"], duration: .always)
        let events = [
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 100), credentialId: "neon", fieldName: "url",
                              subjectFingerprint: "x", subjectDisplayName: "python", mode: .permissive, decision: "allowed_without_grant"),
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "neon", fieldName: "url",
                              subjectFingerprint: "y", subjectDisplayName: "node", mode: .enforced, decision: "prompt_required"),
        ]
        let entries = AccessLogBuilder.entries(serviceGrants: [used, neverUsed], auditEvents: events)
        XCTAssertEqual(entries.map(\.who), ["claude", "node", "python"])
        XCTAssertEqual(entries.map(\.kind), [.approvedUse, .approvalRequired, .readWithoutApproval])
    }

    func test同一调用方反复读同一字段合并成一行并带次数和最近时间() {
        func read(_ t: TimeInterval, _ who: String, _ cred: String, _ field: String) -> ServiceAuditEvent {
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: t), credentialId: cred, fieldName: field,
                              subjectFingerprint: who, subjectDisplayName: who, mode: .permissive,
                              decision: "allowed_without_grant")
        }
        let events = [
            read(100, "python3", "glm", "api-key"),
            read(400, "python3", "glm", "api-key"),
            read(250, "python3", "glm", "api-key"),
            read(300, "console", "feisou-admin", "ADMIN_KEY"),
            read(350, "python3", "glm", "base-url"),
        ]
        let groups = AccessLogBuilder.groups(AccessLogBuilder.entries(serviceGrants: [], auditEvents: events))
        XCTAssertEqual(groups.map(\.who), ["python3", "python3", "console"])
        XCTAssertEqual(groups.map(\.detail), ["api-key", "base-url", "ADMIN_KEY"])
        XCTAssertEqual(groups.map(\.count), [3, 1, 1])
        XCTAssertEqual(groups.first?.latest, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(groups.first?.kind, .readWithoutApproval)
    }
}
