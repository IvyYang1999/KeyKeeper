import XCTest
@testable import KeyKeeperCore

final class BrowserSessionTests: XCTestCase {
    private func fixture(origin: String = "https://app.example.com") -> BrowserSessionImport {
        .init(id: UUID().uuidString, origin: origin, label: "Work profile", cookies: [
            .init(name: "session", value: "synthetic-fixture", domain: ".example.com", hostOnly: false,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
    }
    func testSelectedHTTPSOriginAndParentCookieAcceptedWithoutRewritingInput() throws {
        let input = fixture()
        try input.validate()
        XCTAssertEqual(input.cookies[0].domain, ".example.com")
        XCTAssertEqual(try BrowserSessionImport.canonicalOrigin(input.origin), input.origin)
    }
    func testRejectUnselectedDomainsAndNonCanonicalOrigins() {
        for origin in ["http://example.com", "https://user@example.com", "https://example.com/path",
                       "https://example.com?secret=x", "file:///tmp/a", "https://example.com#fragment"] {
            XCTAssertThrowsError(try fixture(origin: origin).validate())
        }
        for domain in ["evil.com", "ample.com", "example.com.evil.com"] {
            var input = fixture(); input.cookies[0].domain = domain
            XCTAssertThrowsError(try input.validate())
        }
        var input = fixture(); input.cookies[0].hostOnly = true
        XCTAssertThrowsError(try input.validate())
    }
    func testBoundsExpiryCookieInjectionAndUnsupportedScopesFailClosed() {
        var input = fixture(); input.cookies = []
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies = Array(repeating: input.cookies[0], count: 65)
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies[0].value = "x\r\nDomain=evil.com"
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies[0].value = String(repeating: "x", count: 4097)
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies[0].expirationDate = 1
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies[0].path = "/account"
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies[0].sameSite = "unknown"
        XCTAssertThrowsError(try input.validate())
        input = fixture(); input.cookies.append(input.cookies[0])
        XCTAssertThrowsError(try input.validate())
    }
    func testMetadataResponseContainsNoCookieNamesOrValues() throws {
        let input = fixture()
        let summary = BrowserSessionSummary(snapshot: input, createdAt: Date())
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        XCTAssertFalse(encoded.contains("synthetic-fixture"))
        XCTAssertFalse(encoded.contains("httpOnly"))
        XCTAssertEqual(summary.cookieCount, 1)
    }
}
