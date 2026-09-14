import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【独立审计 2026-09-13】授权列表把调用方自报的显示名原样画出来——授权窗里早就过滤了，这里漏了。
@MainActor
final class AccessEntryDisplayTests: XCTestCase {
    func test调用方显示名经过过滤() {
        let approval = Approval(subject: .init(fingerprint: "unsigned:path=abc", displayName: "Codex\u{202E}exe.txt\nApproved by you"),
                                target: .credential(id: "c", fields: ["f"]), duration: .always)
        let who = AccessEntryBuilder.entries(approvals: [approval]).first?.who ?? ""
        XCTAssertFalse(who.contains("\u{202E}"), who)
        XCTAssertFalse(who.contains("\n"), who)
        XCTAssertTrue(who.hasPrefix("Codex"), who)
    }

    /// 未核实身份的授权对谁都不生效，列表不能把它画成有效的「始终」。列表说有效，就得真的有效。
    func test未核实的授权显示为已失效() {
        let unverified = Approval(subject: .init(fingerprint: CallerSubject.unverifiedPrefix + "x", displayName: "?"),
                                  target: .credential(id: "c", fields: nil), duration: .always)
        let owned = Approval(subject: .init(fingerprint: "unsigned:path=abc", displayName: "Codex"),
                             target: .credential(id: "c", fields: nil), duration: .always)
        let entries = AccessEntryBuilder.entries(approvals: [unverified, owned])
        XCTAssertEqual(entries.first { $0.id == "approval:\(unverified.id)" }?.isActive, false)
        XCTAssertEqual(entries.first { $0.id == "approval:\(owned.id)" }?.isActive, true)
        XCTAssertTrue(entries.first { $0.id == "approval:\(owned.id)" }?.who.contains("Codex") == true, "写出这条授权属于谁")
    }
}
