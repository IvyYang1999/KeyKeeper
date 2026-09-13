import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-13：「扩展和这个方法可以并存」——除了从 Chrome 导入，还应该能直接在
/// KeyKeeper 自己的隔离窗口里登录一次，登录态长在 KeyKeeper 这边，全程不需要扩展。
///
/// 这一层只管「登录窗口里拿到的一堆 cookie，哪些该留下、留下来长什么样」，不碰窗口。
final class BrowserSessionCaptureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)
    private func cookie(_ name: String, domain: String = "example.com", path: String = "/",
                        secure: Bool = true, expires: Double? = nil,
                        sameSite: String = "lax") -> CapturedCookie {
        CapturedCookie(name: name, value: "synthetic-\(name)", domain: domain, path: path,
                       secure: secure, httpOnly: true, sameSite: sameSite, expiresAt: expires)
    }

    func test只留下这个站点根路径上的cookie() throws {
        let snapshot = try BrowserSessionCapture.snapshot(
            origin: "https://example.com", label: "示例",
            cookies: [cookie("session"),
                      cookie("scoped", path: "/admin"),
                      cookie("elsewhere", domain: "other.invalid"),
                      cookie("parent", domain: ".example.com")],
            now: now, id: UUID().uuidString)
        XCTAssertEqual(snapshot.cookies.map(\.name).sorted(), ["parent", "session"])
        XCTAssertNoThrow(try snapshot.validate(now: now))
    }

    /// 登录窗口里会顺带产生一堆已经过期的 cookie，存进去只会让快照一打开就失效。
    func test过期的直接丢掉() throws {
        let snapshot = try BrowserSessionCapture.snapshot(
            origin: "https://example.com", label: "示例",
            cookies: [cookie("live", expires: now.timeIntervalSince1970 + 3600),
                      cookie("stale", expires: now.timeIntervalSince1970 - 1)],
            now: now, id: UUID().uuidString)
        XCTAssertEqual(snapshot.cookies.map(\.name), ["live"])
    }

    /// 一个 cookie 都没有，多半是根本没登录成功。存一个空快照比不存更糟——
    /// 它看起来像个可用的登录态。
    func test一条都不剩就报错而不是存个空壳() {
        XCTAssertThrowsError(try BrowserSessionCapture.snapshot(
            origin: "https://example.com", label: "示例",
            cookies: [cookie("scoped", path: "/admin")], now: now, id: UUID().uuidString)) {
            XCTAssertEqual($0 as? BrowserSessionError, .invalidImport)
        }
    }

    /// 和扩展那条路存进来的快照必须长得一模一样——两条路共用同一套校验和同一个存储。
    func test产出的快照与扩展导入的通过同一套校验() throws {
        let snapshot = try BrowserSessionCapture.snapshot(
            origin: "https://example.com", label: "  示例  ",
            cookies: (1...70).map { cookie("c\($0)") }, now: now, id: UUID().uuidString)
        XCTAssertEqual(snapshot.cookies.count, 64, "上限和扩展那条路一致，多的截掉而不是整批失败")
        XCTAssertEqual(snapshot.label, "示例", "标签两端的空白要修掉，否则校验会挂")
        XCTAssertNoThrow(try snapshot.validate(now: now))
    }

    func test非法站点直接拒绝() {
        for bad in ["http://example.com", "https://example.com/path", "https://EXAMPLE.com", "example.com"] {
            XCTAssertThrowsError(try BrowserSessionCapture.snapshot(
                origin: bad, label: "示例", cookies: [cookie("session")], now: now, id: UUID().uuidString), bad)
        }
    }
}
