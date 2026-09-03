import ArgumentParser
import XCTest
@testable import KeyKeeperCLI

final class CommandFailureTests: XCTestCase {
    /// 【曾经的 bug】运行期错误用 ValidationError 抛出，每条后面都跟着 "Usage: keykeeper <subcommand>" 噪音。
    func test曾经的Bug运行期错误不再附带Usage() {
        let failure = CommandFailure("Credential 'x' not found. Run 'keykeeper list' to see the available IDs.")
        let message = KeyKeeperCommand.fullMessage(for: failure)
        XCTAssertTrue(message.contains("keykeeper list"))
        XCTAssertFalse(message.contains("Usage"))
        XCTAssertNotEqual(KeyKeeperCommand.exitCode(for: failure), .success)

        let validation = ValidationError("bad args")
        XCTAssertTrue(KeyKeeperCommand.fullMessage(for: validation).contains("Usage"))
    }
}
