import XCTest
@testable import KeyKeeperCore

/// Agent 新建凭据时可以建议保护方式和过期日。只在新建时有意义；人在保存窗里看到建议再决定。
final class SaveSuggestionTests: XCTestCase {
    func test建议只能跟新建一起用() {
        XCTAssertThrowsError(try ClipboardSaveRequest(credentialId: "a", fieldName: "k", security: .standard).validate())
        XCTAssertThrowsError(try ClipboardSaveRequest(credentialId: "a", fieldName: "k", expires: "2026-12-31").validate())
        XCTAssertNoThrow(try ClipboardSaveRequest(credentialId: "a", fieldName: "k", create: true,
                                                  security: .standard, expires: "2026-12-31").validate())
        XCTAssertThrowsError(try ClipboardSaveRequest(credentialId: "a", fieldName: "k", create: true, expires: "2026-02-30").validate())
    }

    func test不带建议的请求编码不变() throws {
        let data = try JSONEncoder().encode(ClipboardSaveRequest(credentialId: "a", fieldName: "k", create: true))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("security")); XCTAssertFalse(text.contains("expires"))
        let decoded = try JSONDecoder().decode(ClipboardSaveRequest.self, from: data)
        XCTAssertNil(decoded.security); XCTAssertNil(decoded.expires)
    }
}
