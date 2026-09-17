import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AccessLogBuilderTests: XCTestCase {
    /// 已结束的请求属于历史，不得与仍可点击批准的请求混作一行。
    func test错过的授权有独立状态而不是活请求() {
        let event = ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "siliconflow",
                                      fieldName: "api-key", subjectFingerprint: "app:agent",
                                      subjectDisplayName: "Agent", mode: .enforced,
                                      decision: "missed_approval", requestID: "request-1")
        let row = AccessLogBuilder.entries(approvals: [], auditEvents: [event])[0]
        XCTAssertEqual(row.kind, .missedApproval)
    }

    func test旧审计记录没有请求ID仍可解码() throws {
        let old = Data(#"{"timestamp":200,"credentialId":"fixture","fieldName":"key","subjectFingerprint":"app:old","subjectDisplayName":"Old","mode":"enforced","decision":"prompt_required"}"#.utf8)
        let event = try JSONDecoder().decode(ServiceAuditEvent.self, from: old)
        XCTAssertNil(event.requestID)
        XCTAssertEqual(event.credentialId, "fixture")
    }

    func test已结束请求只显示错过记录不保留可预授权的旧行() {
        let requested = ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 100), credentialId: "fixture",
            fieldName: "key", subjectFingerprint: "app:agent", subjectDisplayName: "Agent",
            mode: .enforced, decision: "prompt_required", requestID: "call-1")
        let missed = ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "fixture",
            fieldName: "key", subjectFingerprint: "app:agent", subjectDisplayName: "Agent",
            mode: .enforced, decision: "missed_approval", requestID: "call-1")
        let rows = AccessLogBuilder.entries(approvals: [], auditEvents: [requested, missed])
        XCTAssertEqual(rows.map(\.kind), [.missedApproval])
    }

    /// 【曾经的 bug】显示名不是授权身份：两个同名进程的历史不能合并后拿第一条的指纹审批。
    func test同名但不同身份的请求绝不合并() {
        let events = ["app:first", "app:second"].map { fingerprint in
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "fixture", fieldName: "key",
                              subjectFingerprint: fingerprint, subjectDisplayName: "Same App",
                              mode: .enforced, decision: "prompt_required")
        }
        let groups = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: events))
        XCTAssertEqual(groups.count, 2, "显示名称相同不能共享历史或审批入口")
        XCTAssertEqual(Set(groups.map(\.fingerprint)), Set(["app:first", "app:second"]))
        XCTAssertTrue(groups.allSatisfy { $0.count == 1 })
    }

    func test合并授权使用与审计事件并按时间倒序() {
        let used = Approval(subject: .init(fingerprint: "fp", displayName: "claude"), target: .credential(id: "openai", fields: ["api-key"]),
                            duration: .always, lastUsedAt: Date(timeIntervalSince1970: 300))
        let neverUsed = Approval(subject: .init(fingerprint: "fp2", displayName: "cron"), target: .credential(id: "stripe", fields: ["secret-key"]),
                                 duration: .always)
        let events = [
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 100), credentialId: "neon", fieldName: "url",
                              subjectFingerprint: "x", subjectDisplayName: "python", mode: .permissive, decision: "allowed_without_grant"),
            ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "neon", fieldName: "url",
                              subjectFingerprint: "y", subjectDisplayName: "node", mode: .enforced, decision: "prompt_required"),
        ]
        let entries = AccessLogBuilder.entries(approvals: [used, neverUsed], auditEvents: events)
        XCTAssertEqual(entries.map(\.who), ["claude", "node", "python"])
        XCTAssertEqual(entries.map(\.kind), [.approvedUse, .approvalRequired, .readWithoutApproval])
        XCTAssertEqual(entries.map(\.fingerprint), ["fp", "y", "x"], "每条都带主体指纹，这样「请求了批准」的能原地批准")
    }

    /// yyt 2026-09-15：「未批准也没有拒绝的请求，能不能点击重新打开弹窗审批」。审计条目变成一个可以
    /// 重新发起的常设授权请求；认不出的主体不能。
    func test请求了批准的条目可以变成常设授权请求() {
        let event = ServiceAuditEvent(timestamp: Date(timeIntervalSince1970: 200), credentialId: "feisou-admin", fieldName: "ADMIN_KEY",
                                      subjectFingerprint: "relayed:app:unsigned:path=abc", subjectDisplayName: "com.darkconstant.console",
                                      mode: .enforced, decision: "prompt_required", reason: "nightly sync", command: "node live.js")
        let group = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: [event]))[0]
        let request = try! XCTUnwrap(StandingApprovalRequest(group: group, credentialLabel: "飞搜 admin", fieldNames: ["ADMIN_KEY"]))
        XCTAssertEqual(request.callerIdentity.subject.fingerprint, "relayed:app:unsigned:path=abc")
        XCTAssertEqual(request.callerIdentity.subject.kind, .app)
        XCTAssertEqual(request.reason, "nightly sync")
        XCTAssertEqual(request.command, "node live.js")
        let prompt = AuthorizationPrompt.standing(request)
        XCTAssertEqual(prompt.credentialLabel, "飞搜 admin")
        XCTAssertEqual(prompt.statedReason?.text, "nightly sync")
        XCTAssertFalse(prompt.hasTerminalSession)
        let unverified = ServiceAuditEvent(timestamp: Date(), credentialId: "c", fieldName: "f", subjectFingerprint: CallerSubject.unverifiedPrefix + "x",
                                           subjectDisplayName: "?", mode: .enforced, decision: "prompt_required")
        let g2 = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: [unverified]))[0]
        XCTAssertNil(StandingApprovalRequest(group: g2, credentialLabel: "c", fieldNames: ["f"]), "认不出的主体存不了授权，也就没有按钮")
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
        let groups = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: events))
        XCTAssertEqual(groups.map(\.who), ["python3", "python3", "console"])
        XCTAssertEqual(groups.map(\.detail), ["api-key", "base-url", "ADMIN_KEY"])
        XCTAssertEqual(groups.map(\.count), [3, 1, 1])
        XCTAssertEqual(groups.first?.latest, Date(timeIntervalSince1970: 400))
        XCTAssertEqual(groups.first?.kind, .readWithoutApproval)
    }
}
