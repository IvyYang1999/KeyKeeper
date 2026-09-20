import XCTest
@testable import KeyKeeperApp

final class BrowserImportHTTPTests: XCTestCase {
    private let host = "127.0.0.1:45678"
    private func request(_ extra: String = "", body: String = "synthetic") -> Data {
        Data("POST /import HTTP/1.1\r\nHost: \(host)\r\nOrigin: http://\(host)\r\nContent-Type: text/plain;charset=UTF-8\r\nX-KeyKeeper-Session: test-ticket\r\nContent-Length: \(body.utf8.count)\r\n\(extra)\r\n\(body)".utf8)
    }
    private func status(ticket: String = "test-ticket", origin: String? = nil) -> Data {
        Data("POST /status HTTP/1.1\r\nHost: \(host)\r\nOrigin: \(origin ?? "http://\(host)")\r\nContent-Type: text/plain\r\nX-KeyKeeper-Session: \(ticket)\r\nContent-Length: 6\r\n\r\nstatus".utf8)
    }
    func testValidExactOriginAndIncrementalBody() throws {
        let data = request()
        XCTAssertNil(try BrowserImportHTTP.parse(data.dropLast(), host: host, ticket: "test-ticket"))
        XCTAssertEqual(try BrowserImportHTTP.parse(data, host: host, ticket: "test-ticket")?.body, Data("synthetic".utf8))
    }
    func testRejectWrongHostOriginTicketAndAmbiguousFraming() {
        let good = String(decoding: request(), as: UTF8.self)
        for altered in [good.replacingOccurrences(of: "Host: \(host)", with: "Host: evil.test"),
                        good.replacingOccurrences(of: "Origin: http://\(host)", with: "Origin: https://evil.test"),
                        good.replacingOccurrences(of: "test-ticket", with: "wrong"),
                        String(decoding: request("Content-Length: 9\r\n"), as: UTF8.self),
                        String(decoding: request("Transfer-Encoding: chunked\r\n"), as: UTF8.self),
                        good + "extra"] {
            XCTAssertThrowsError(try BrowserImportHTTP.parse(Data(altered.utf8), host: host, ticket: "test-ticket"))
        }
    }
    func testBoundedHeadersBodyAndRoutes() {
        XCTAssertThrowsError(try BrowserImportHTTP.parse(Data(repeating: 65, count: 8193), host: host, ticket: "test-ticket"))
        XCTAssertThrowsError(try BrowserImportHTTP.parse(request(body: String(repeating: "x", count: 65537)), host: host, ticket: "test-ticket"))
        XCTAssertThrowsError(try BrowserImportHTTP.parse(Data("GET /unknown HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8), host: host, ticket: "test-ticket"))
    }
    func testStatusRequiresExactOriginAndTicket() throws {
        XCTAssertEqual(try BrowserImportHTTP.parse(status(), host: host, ticket: "test-ticket")?.path, "/status")
        XCTAssertThrowsError(try BrowserImportHTTP.parse(status(ticket: "wrong"), host: host, ticket: "test-ticket"))
        XCTAssertThrowsError(try BrowserImportHTTP.parse(status(origin: "https://evil.test"), host: host, ticket: "test-ticket"))
    }
}
