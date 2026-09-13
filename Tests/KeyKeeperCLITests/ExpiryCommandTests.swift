import XCTest
@testable import KeyKeeperCLI

final class ExpiryCommandTests: XCTestCase {
    func test编辑命令可以设和清过期时间() throws {
        XCTAssertEqual(try EditCommand.parse(["openai", "--expires", "2026-12-31"]).request().edit.expires, "2026-12-31")
        XCTAssertEqual(try EditCommand.parse(["openai", "--expires", "never"]).request().edit.expires, "never")
    }
}
