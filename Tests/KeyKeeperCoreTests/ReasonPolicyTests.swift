import XCTest
@testable import KeyKeeperCore

final class ReasonPolicyTests: XCTestCase {
    /// yyt 2026-09-15：0.3.4 里「没理由就拒」把 0.3.4 之前写好的集成（Dark Console 的后台读取等）全都
    /// 静默弄挂了——它们不带 --reason，stderr 又被丢掉。现在没理由照样弹窗，只是窗口里明说、推荐降到
    /// 「仅这一次」；理由仍然是 skill 里的硬要求。
    func test没有理由_不拒_给窗口一句提示() {
        XCTAssertNotNil(ReasonPolicy.missingReasonNote(statedReason: nil, callerName: "codex"))
        XCTAssertNotNil(ReasonPolicy.missingReasonNote(statedReason: CallerStatedReason.sanitize("  \u{200B} "), callerName: "codex"))
        XCTAssertNil(ReasonPolicy.missingReasonNote(statedReason: CallerStatedReason.sanitize("deploying preview"), callerName: "codex"))
        let note = ReasonPolicy.missingReasonNote(statedReason: nil, callerName: "codex")!
        XCTAssertTrue(note.contains("codex"), note)
    }

    func test理由记进授权和审计记录_旧记录没有也能读() throws {
        let approval = Approval(subject: .init(fingerprint: "unsigned:path=a", displayName: "a"),
                                target: .credential(id: "c", fields: nil), duration: .always, reason: "deploying preview")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Approval.self, from: encoder.encode(approval)).reason, "deploying preview")
        let old = Data(#"{"timestamp":"2026-09-12T09:00:00Z","credentialId":"c","fieldName":"f","subjectFingerprint":"x","subjectDisplayName":"x","mode":"permissive","decision":"allowed_without_grant"}"#.utf8)
        XCTAssertNil(try decoder.decode(ServiceAuditEvent.self, from: old).reason)
        let plain = try JSONEncoder().encode(Approval(subject: .init(fingerprint: "unsigned:path=a", displayName: "a"),
                                                      target: .credential(id: "c", fields: nil), duration: .always))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("reason"), "没理由就不写这个键")
    }
}
