import XCTest
@testable import KeyKeeperCore

final class ReasonPolicyTests: XCTestCase {
    func test没有理由就拒_有理由就放() {
        XCTAssertNotNil(ReasonPolicy.refusal(statedReason: nil, callerName: "codex", credentialLabel: "vercel"))
        XCTAssertNotNil(ReasonPolicy.refusal(statedReason: CallerStatedReason.sanitize("  \u{200B} "), callerName: "codex", credentialLabel: "vercel"))
        XCTAssertNil(ReasonPolicy.refusal(statedReason: CallerStatedReason.sanitize("deploying preview"), callerName: "codex", credentialLabel: "vercel"))
        let message = ReasonPolicy.refusal(statedReason: nil, callerName: "codex", credentialLabel: "vercel")!
        XCTAssertTrue(message.contains("--reason") && message.contains("codex") && message.contains("vercel"), message)
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
