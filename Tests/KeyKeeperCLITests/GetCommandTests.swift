import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class GetCommandTests: XCTestCase {
    func test终端输出默认拒绝管道输出放行() {
        XCTAssertTrue(GetCommand.refusesToPrint(stdoutIsTerminal: true, reveal: false))
        XCTAssertFalse(GetCommand.refusesToPrint(stdoutIsTerminal: false, reveal: false))
        XCTAssertFalse(GetCommand.refusesToPrint(stdoutIsTerminal: true, reveal: true))
    }

    func test拒绝文案指向run与reveal() {
        XCTAssertTrue(GetCommand.terminalRefusalMessage.contains("keykeeper run"))
        XCTAssertTrue(GetCommand.terminalRefusalMessage.contains("--reveal"))
    }

    func testReveal标志可解析() throws {
        let command = try GetCommand.parse(["openai", "api-key", "--reveal"])
        XCTAssertTrue(command.reveal)
        XCTAssertFalse(try GetCommand.parse(["openai", "api-key"]).reveal)
    }
}
