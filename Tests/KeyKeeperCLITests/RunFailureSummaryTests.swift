import XCTest
@testable import KeyKeeperCLI

final class RunFailureSummaryTests: XCTestCase {
    // 【曾经的 bug】子命令失败会让 Agent 把供应商响应误判成 KeyKeeper 注入失败。
    func testFailedChildIsDistinguishedFromSuccessfulInjection() {
        XCTAssertNil(RunCommand.failureSummary(exitStatus: 0, injectedVariableCount: 2))
        XCTAssertEqual(
            RunCommand.failureSummary(exitStatus: 23, injectedVariableCount: 2),
            "KeyKeeper: injected 2 environment variables. Command exited with status 23. Provider acceptance and request correctness were not verified."
        )
    }

    func testNoInjectionDoesNotClaimAKeyWasUsed() {
        XCTAssertEqual(
            RunCommand.failureSummary(exitStatus: 7, injectedVariableCount: 0),
            "KeyKeeper: no values were injected. Command exited with status 7. Provider acceptance and request correctness were not verified."
        )
    }
}
