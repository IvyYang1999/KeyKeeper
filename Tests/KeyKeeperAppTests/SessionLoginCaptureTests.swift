import AppKit
import WebKit
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// WebKit 交出来的 cookie 要原样接住——「哪些该留下」是 BrowserSessionCapture 的问题，
/// 这一层只负责不歪曲事实。SameSite 尤其容易错：把 Strict 读成 Lax 就等于悄悄放宽了
/// 网站自己定的认证策略。
@MainActor final class SessionLoginCaptureTests: XCTestCase {
    private func cookie(_ properties: [HTTPCookiePropertyKey: Any]) throws -> HTTPCookie {
        var base: [HTTPCookiePropertyKey: Any] = [
            .name: "session", .value: "synthetic", .domain: "example.com", .path: "/",
        ]
        for (key, value) in properties { base[key] = value }
        return try XCTUnwrap(HTTPCookie(properties: base))
    }

    func test属性原样接住不歪曲() throws {
        let captured = SessionLoginWindow.captured(try cookie([
            .secure: "TRUE", .init("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue,
        ]))
        XCTAssertEqual(captured.name, "session")
        XCTAssertEqual(captured.domain, "example.com")
        XCTAssertEqual(captured.path, "/")
        XCTAssertTrue(captured.secure)
        XCTAssertEqual(captured.sameSite, "strict")
        XCTAssertNil(captured.expiresAt, "会话 cookie 没有过期时间，不能编一个出来")
    }

    func testSameSite没写的时候说没写不是说Lax() throws {
        XCTAssertEqual(SessionLoginWindow.captured(try cookie([:])).sameSite, "unspecified")
        XCTAssertEqual(SessionLoginWindow.captured(try cookie([
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue])).sameSite, "lax")
    }

    func test过期时间按秒传下去() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let captured = SessionLoginWindow.captured(try cookie([.expires: expiry]))
        XCTAssertEqual(captured.expiresAt ?? 0, expiry.timeIntervalSince1970, accuracy: 1)
    }

    /// 登录窗口拿到的东西，要能原样喂给和扩展共用的那套校验。
    func test接住之后能直接生成快照() throws {
        let captured = [SessionLoginWindow.captured(try cookie([
            .secure: "TRUE", .init("HttpOnly"): "TRUE",
            .sameSitePolicy: HTTPCookieStringPolicy.sameSiteLax.rawValue]))]
        let snapshot = try BrowserSessionCapture.snapshot(origin: "https://example.com",
                                                          label: "示例", cookies: captured)
        XCTAssertEqual(snapshot.cookies.count, 1)
        XCTAssertNoThrow(try snapshot.validate())
    }
}
