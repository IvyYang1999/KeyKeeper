import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class StatusCommandTests: XCTestCase {
    func testApp可达时报告ready() {
        let output = StatusCommand.report {
            SessionControlResponse(success: true, state: .unlockedManual)
        }
        XCTAssertEqual(output, "ready")
    }

    func testApp未运行时说明会自动启动() {
        let output = StatusCommand.report { throw IPCError.appNotRunning }
        XCTAssertTrue(output.contains("starts automatically"))
    }

    func testUnlock与Lock子命令已移除() {
        XCTAssertThrowsError(try KeyKeeperCommand.parseAsRoot(["unlock"]))
        XCTAssertThrowsError(try KeyKeeperCommand.parseAsRoot(["lock"]))
    }
}
