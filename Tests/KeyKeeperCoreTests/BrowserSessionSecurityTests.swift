import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-13：「存 Cookie 这件事，就是把自己账号的登录权交给了 Agent。理应做到和
/// keykeeper 的其它体验一致的。」
///
/// key 有安全级别（后台放行 / 每次询问）和带时长的授权；登录态原来只有一种行为——每次
/// 都问、15 分钟砍掉。这一层先给登录态一个自己的安全级别。
final class BrowserSessionSecurityTests: XCTestCase {
    private func snapshot(id: String = UUID().uuidString) -> BrowserSessionImport {
        BrowserSessionImport(id: id, origin: "https://example.com", label: "示例",
            cookies: [BrowserSessionCookie(name: "session", value: "synthetic", domain: "example.com",
                hostOnly: true, path: "/", secure: true, httpOnly: true,
                sameSite: "lax", expirationDate: nil)])
    }
    private func store() -> (BrowserSessionStore, InMemoryBlobIO, MemoryMarker) {
        let io = InMemoryBlobIO()
        let marker = MemoryMarker()
        return (BrowserSessionStore(io: io, marker: marker), io, marker)
    }

    /// 新存进来的登录态默认「每次询问」——这是用户至今为止一直在做的事，不能因为改了
    /// 模型就替他们放宽。
    func test新快照默认每次询问() throws {
        let (store, _, _) = store()
        let summary = try store.save(snapshot())
        XCTAssertEqual(summary.security, .strict)
    }

    func test可以改成后台放行并且存得住() throws {
        let (store, _, _) = store()
        let saved = try store.save(snapshot())
        try store.setSecurity(id: saved.id, to: .standard)
        XCTAssertEqual(try store.list().first?.security, .standard)
        try store.setSecurity(id: saved.id, to: .strict)
        XCTAssertEqual(try store.list().first?.security, .strict)
        XCTAssertThrowsError(try store.setSecurity(id: "nope", to: .standard))
    }

    /// 0.3.3 写的文件里没有这个字段。读到旧文件时不能崩，也不能悄悄变成「后台放行」。
    func test旧文件读出来当作每次询问() throws {
        let (store, io, marker) = store()
        let saved = try store.save(snapshot())
        // 模拟旧版写的记录：把 security 键整个抹掉
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: io.blob ?? Data()) as? [String: Any])
        var records = try XCTUnwrap(object["records"] as? [String: Any])
        var record = try XCTUnwrap(records[saved.id] as? [String: Any])
        record.removeValue(forKey: "security")
        records[saved.id] = record
        object["records"] = records
        io.blob = try JSONSerialization.data(withJSONObject: object)

        let reloaded = BrowserSessionStore(io: io, marker: marker)
        XCTAssertEqual(try reloaded.list().first?.security, .strict, "读不到就按最严的算")
    }
}

private final class InMemoryBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data }
}

private final class MemoryMarker: BrowserSessionMarker {
    var exists = false
    func wasCreated() throws -> Bool { exists }
    func markCreated() throws { exists = true }
}
