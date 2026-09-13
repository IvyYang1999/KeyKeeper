import XCTest
@testable import KeyKeeperCore

/// 登录态的授权：和 key 一样的三档时长（仅本次 / 1 小时 / 始终允许），和 ServiceGrant
/// 一样按调用方指纹匹配。
///
/// 但**存的地方不一样**：key 的授权躺在明文 grants.json / service-grants.json 里，而这套
/// 的威胁模型里，对手正是「同一个用户下的本地进程」——它对那个文件有完全写权限。今天
/// 每次开窗都要真人点一下，所以改文件也没用；一旦「始终允许」上线，往文件里追加一条
/// 就能无声开出一个已登录窗口。所以登录态的授权和快照存在同一个钥匙串条目里。
final class BrowserSessionGrantTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func snapshot(id: String) -> BrowserSessionImport {
        BrowserSessionImport(id: id, origin: "https://example.com", label: "示例",
            cookies: [BrowserSessionCookie(name: "s", value: "synthetic", domain: "example.com",
                hostOnly: true, path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)])
    }
    private func store() -> (BrowserSessionStore, GrantTestIO) {
        let io = GrantTestIO()
        return (BrowserSessionStore(io: io, marker: GrantTestMarker()), io)
    }

    func test授权按登录态和调用方两者匹配() throws {
        let (store, _) = store()
        let a = UUID().uuidString, b = UUID().uuidString
        _ = try store.save(snapshot(id: a), now: now)
        _ = try store.save(snapshot(id: b), now: now)
        try store.addGrant(.init(sessionId: a, subjectFingerprint: "app:bundle=com.example.agent",
                                 subjectDisplayName: "Agent", duration: .always, createdAt: now))

        XCTAssertNotNil(try store.validGrant(sessionId: a, fingerprint: "app:bundle=com.example.agent", now: now))
        XCTAssertNil(try store.validGrant(sessionId: a, fingerprint: "app:bundle=com.other", now: now),
                     "换个调用方就不算数")
        XCTAssertNil(try store.validGrant(sessionId: b, fingerprint: "app:bundle=com.example.agent", now: now),
                     "换条登录态也不算数")
    }

    func test三档时长各自的失效方式() throws {
        let (store, _) = store()
        let id = UUID().uuidString
        _ = try store.save(snapshot(id: id), now: now)

        let once = BrowserSessionGrant(sessionId: id, subjectFingerprint: "f", subjectDisplayName: "A",
                                       duration: .once, createdAt: now)
        try store.addGrant(once)
        XCTAssertNotNil(try store.validGrant(sessionId: id, fingerprint: "f", now: now))
        try store.consumeGrant(id: once.id)
        XCTAssertNil(try store.validGrant(sessionId: id, fingerprint: "f", now: now), "用过一次就没了")

        try store.addGrant(.init(sessionId: id, subjectFingerprint: "g", subjectDisplayName: "B",
                                 duration: .timed(now.addingTimeInterval(3600)), createdAt: now))
        XCTAssertNotNil(try store.validGrant(sessionId: id, fingerprint: "g", now: now.addingTimeInterval(3599)))
        XCTAssertNil(try store.validGrant(sessionId: id, fingerprint: "g", now: now.addingTimeInterval(3600)))
    }

    /// 删掉登录态，它的授权必须跟着走——否则重新存一条同 ID 的就能复活旧授权。
    func test删掉登录态连授权一起删() throws {
        let (store, _) = store()
        let id = UUID().uuidString
        _ = try store.save(snapshot(id: id), now: now)
        try store.addGrant(.init(sessionId: id, subjectFingerprint: "f", subjectDisplayName: "A",
                                 duration: .always, createdAt: now))
        try store.delete(id: id)
        XCTAssertEqual(try store.grants(for: id).count, 0)
    }

    func test可以列出与撤销() throws {
        let (store, _) = store()
        let id = UUID().uuidString
        _ = try store.save(snapshot(id: id), now: now)
        let grant = BrowserSessionGrant(sessionId: id, subjectFingerprint: "f", subjectDisplayName: "Agent",
                                        duration: .always, createdAt: now)
        try store.addGrant(grant)
        XCTAssertEqual(try store.grants(for: id).map(\.subjectDisplayName), ["Agent"])
        try store.revokeGrant(id: grant.id)
        XCTAssertEqual(try store.grants(for: id).count, 0)
    }

    /// 0.3.3 写的文档里没有这个数组，读出来要当作「没有任何授权」，而不是崩掉。
    func test旧文档没有授权数组也能读() throws {
        let (store, io) = store()
        let id = UUID().uuidString
        _ = try store.save(snapshot(id: id), now: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: io.blob ?? Data()) as? [String: Any])
        object.removeValue(forKey: "grants")
        io.blob = try JSONSerialization.data(withJSONObject: object)
        let reloaded = BrowserSessionStore(io: io, marker: GrantTestMarker())
        XCTAssertEqual(try reloaded.grants(for: id).count, 0)
    }
}

private final class GrantTestIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data }
}
private final class GrantTestMarker: BrowserSessionMarker {
    var exists = false
    func wasCreated() throws -> Bool { exists }
    func markCreated() throws { exists = true }
}
