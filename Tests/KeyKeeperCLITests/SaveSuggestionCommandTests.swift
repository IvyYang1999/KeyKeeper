import XCTest
@testable import KeyKeeperCLI

final class SaveSuggestionCommandTests: XCTestCase {
    func test保存命令带上建议() throws {
        let command = try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create",
                                             "--security", "standard", "--expires", "2026-12-31"])
        XCTAssertEqual(command.request.security, .standard)
        XCTAssertEqual(command.request.expires, "2026-12-31")
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--security", "standard"]),
                             "不是新建就没有建议可言")
    }
}
