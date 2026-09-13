import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class SessionBrowserPolicyTests: XCTestCase {
    func testCookieConversionNarrowsDomainAndPreservesHttpOnlyAndSecure() throws {
        let original = BrowserSessionCookie(name: "fixture", value: "synthetic", domain: ".example.com", hostOnly: false,
            path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        let converted = try SessionBrowserPolicy.cookie(original, origin: "https://app.example.com")
        XCTAssertEqual(converted.domain, "app.example.com")
        XCTAssertTrue(converted.isHTTPOnly); XCTAssertTrue(converted.isSecure)
        XCTAssertEqual(converted.value, "synthetic")
        XCTAssertEqual(converted.path, "/")
        XCTAssertEqual(converted.sameSitePolicy?.rawValue.lowercased(), "lax")
        for (source, expected) in [("strict", "strict"), ("unspecified", "lax")] {
            var input = original; input.sameSite = source
            XCTAssertEqual(try SessionBrowserPolicy.cookie(input, origin: "https://app.example.com").sameSitePolicy?.rawValue.lowercased(), expected)
        }
        var unsupported = original; unsupported.sameSite = "no_restriction"
        XCTAssertThrowsError(try SessionBrowserPolicy.cookie(unsupported, origin: "https://app.example.com")) { error in
            XCTAssertEqual(error as? BrowserSessionError, .unsupported)
        }
    }
    func testNavigationRejectsLookalikesDownloadsProtocolsAndOtherPorts() {
        for url in ["https://app.example.com/path?a=1", "https://app.example.com/"] {
            XCTAssertTrue(SessionBrowserPolicy.allows(URL(string: url)!, origin: "https://app.example.com"))
        }
        for url in ["https://app.example.com.evil.com/", "https://evil.com", "https://app.example.com:444/",
                    "http://app.example.com", "file:///tmp/a", "https://user@app.example.com/"] {
            XCTAssertFalse(SessionBrowserPolicy.allows(URL(string: url)!, origin: "https://app.example.com"))
        }
    }

    /// 在 KeyKeeper 里登录时的导航范围必须比回放宽——几乎所有登录都会跳去身份提供方
    /// （SSO、验证码、第三方登录）。但也不能什么都放：只走 https，且不接受把用户名密码
    /// 写在 URL 里的地址。窗口是空的、用完即弃，所以放宽的代价被框住了。
    func test登录期间只放行https() {
        for allowed in ["https://example.com/login",
                        "https://accounts.google.com/o/oauth2/auth",
                        "https://login.microsoftonline.com/common"] {
            XCTAssertTrue(SessionBrowserPolicy.allowsDuringLogin(URL(string: allowed)!), allowed)
        }
        for blocked in ["http://example.com/login",
                        "file:///etc/passwd",
                        "about:blank",
                        "javascript:alert(1)",
                        "https://user:pass@example.com/"] {
            XCTAssertFalse(SessionBrowserPolicy.allowsDuringLogin(URL(string: blocked)!), blocked)
        }
    }
}
