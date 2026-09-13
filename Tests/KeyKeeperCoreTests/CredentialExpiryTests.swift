import XCTest
@testable import KeyKeeperCore

/// 过期时间：API key 创建后大多有有效期，之前完全没记录。人和 Agent 都能填；KeyKeeper 只提醒，不拦、不删。
final class CredentialExpiryTests: XCTestCase {
    private func day(_ value: String) -> Date { CredentialExpiry.date(from: value)! }

    private func meta() -> MetaFile {
        MetaFile(credentials: ["a": Credential(label: "A", notes: "", links: [], fields: ["k": .init(secret: true)],
                                               security: .strict, created: "2026-01-01", updated: "2026-01-01")])
    }

    func test只接受真实存在的日期() {
        XCTAssertEqual(CredentialExpiry.normalize("2026-12-31"), "2026-12-31")
        XCTAssertEqual(CredentialExpiry.normalize(" 2026-12-31\n"), "2026-12-31")
        for bad in ["2026-02-30", "2026-2-3", "31/12/2026", "2026-12-31T00:00:00Z", "tomorrow", ""] {
            XCTAssertNil(CredentialExpiry.normalize(bad), bad)
        }
    }

    func test状态按天算() {
        let today = day("2026-09-13")
        XCTAssertEqual(CredentialExpiry.status(of: "2026-09-12", today: today), .expired(daysAgo: 1))
        XCTAssertEqual(CredentialExpiry.status(of: "2026-09-13", today: today), .expiresSoon(daysLeft: 0))
        XCTAssertEqual(CredentialExpiry.status(of: "2026-09-27", today: today), .expiresSoon(daysLeft: 14))
        XCTAssertEqual(CredentialExpiry.status(of: "2026-12-31", today: today), .valid(daysLeft: 109))
        XCTAssertNil(CredentialExpiry.status(of: nil, today: today))
        XCTAssertEqual(CredentialExpiry.summary("2026-09-10", today: today), "2026-09-10 (expired 3 days ago)")
    }

    func test只在过期后给Agent提醒() {
        let today = day("2026-09-13")
        XCTAssertNil(CredentialExpiry.warning(credentialId: "a", expires: "2026-09-13", today: today), "最后一天还能用")
        XCTAssertNotNil(CredentialExpiry.warning(credentialId: "a", expires: "2026-09-12", today: today))
        XCTAssertNil(CredentialExpiry.warning(credentialId: "a", expires: nil, today: today))
    }

    func test改过期时间不弹窗且留下记录() throws {
        let set = try MetadataEditPlan.apply(MetadataEdit(expires: "2026-12-31"), to: meta(), groupId: "a")
        XCTAssertEqual(set.meta.credentials["a"]?.expires, "2026-12-31")
        XCTAssertEqual(set.changes, [.expiryChanged(from: nil, to: "2026-12-31")])
        let cleared = try MetadataEditPlan.apply(MetadataEdit(expires: "never"), to: set.meta, groupId: "a")
        XCTAssertNil(cleared.meta.credentials["a"]?.expires)
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(expires: "2026-02-30"), to: meta(), groupId: "a"))
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(expires: "2026-12-31"), to: set.meta, groupId: "a"), "没变就是没变")
    }

    func test旧文件没有过期字段也照常解码且不多写一个字段() throws {
        let json = #"{"version":1,"credentials":{"a":{"label":"A","notes":"","links":[],"fields":{"k":{"secret":true}},"security":"strict","created":"2026-01-01","updated":"2026-01-01"}}}"#
        let decoded = try JSONDecoder().decode(MetaFile.self, from: Data(json.utf8))
        XCTAssertNil(decoded.credentials["a"]?.expires)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try encoder.encode(decoded), as: UTF8.self).contains("expires"),
                       "没填就不写，签名前后的内容才一致")
    }
}
