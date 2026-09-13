import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【独立审计 2026-09-13】授权列表把调用方自报的显示名原样画出来——授权窗里早就过滤了，这里漏了。
@MainActor
final class AccessEntryDisplayTests: XCTestCase {
    func test调用方显示名经过过滤() {
        let grant = ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=abc",
                                 subjectDisplayName: "Codex\u{202E}exe.txt\nApproved by you", fields: ["f"], duration: .always)
        let who = AccessEntryBuilder.entries(grants: [], serviceGrants: [grant]).first?.who ?? ""
        XCTAssertFalse(who.contains("\u{202E}"), who)
        XCTAssertFalse(who.contains("\n"), who)
        XCTAssertTrue(who.hasPrefix("Codex"), who)
    }
}

extension AccessEntryDisplayTests {
    /// 【独立审计 2026-09-13】不记主人的旧授权（本机有 54 条）现在对谁都不生效，列表却还把它们画成
    /// 有效的「始终」。未核实身份的授权同理。列表说有效，就得真的有效。
    func test不记主人和未核实的授权显示为已失效() {
        let unowned = Grant(credentialId: "c", duration: .always)
        let unverified = Grant(credentialId: "c", duration: .always,
                               subjectFingerprint: CallerSubject.unverifiedPrefix + "x", subjectDisplayName: "?")
        let owned = Grant(credentialId: "c", duration: .always,
                          subjectFingerprint: "unsigned:path=abc", subjectDisplayName: "Codex")
        let entries = AccessEntryBuilder.entries(grants: [unowned, unverified, owned], serviceGrants: [])
        XCTAssertEqual(entries.first { $0.id == "grant:\(unowned.id)" }?.isActive, false)
        XCTAssertEqual(entries.first { $0.id == "grant:\(unverified.id)" }?.isActive, false)
        XCTAssertEqual(entries.first { $0.id == "grant:\(owned.id)" }?.isActive, true)

        let service = ServiceGrant(credentialId: "c", subjectFingerprint: CallerSubject.unverifiedPrefix + "x",
                                   subjectDisplayName: "?", fields: ["f"], duration: .always)
        XCTAssertEqual(AccessEntryBuilder.entries(grants: [], serviceGrants: [service]).first?.isActive, false)
    }

    /// 授权现在属于某个调用方，列表却只写「任意终端」，看不出是给了谁。
    func test授权列表写出这条授权属于谁() {
        let owned = Grant(credentialId: "c", duration: .always,
                          subjectFingerprint: "unsigned:path=abc", subjectDisplayName: "Codex")
        let who = AccessEntryBuilder.entries(grants: [owned], serviceGrants: []).first?.who ?? ""
        XCTAssertTrue(who.contains("Codex"), who)
    }
}
