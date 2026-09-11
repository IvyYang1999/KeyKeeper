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
}
