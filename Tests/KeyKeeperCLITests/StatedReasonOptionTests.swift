import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

/// `--reason`：Agent 用一句人话说明为什么要这把 key，显示在本来就要弹的授权窗里。
/// 命令行这一侧先消毒一次（App 还会再消毒一次）。
final class StatedReasonOptionTests: XCTestCase {
    func testRun的reason折成一行带进请求() throws {
        let command = try RunCommand.parse(["-c", "cloudflare-billing", "--reason", "  查本月账单\n\n只读一次  ", "--", "true"])
        XCTAssertEqual(command.statedReason()?.text, "查本月账单 只读一次")
        XCTAssertEqual(command.statedReason()?.truncated, false)
        XCTAssertNil(try RunCommand.parse(["-c", "x", "--", "true"]).statedReason(), "不写就是没有")
    }

    func test超长的reason截断而不是报错() throws {
        let command = try RunCommand.parse(["-c", "x", "--reason", String(repeating: "长", count: 300), "--", "true"])
        let reason = try XCTUnwrap(command.statedReason())
        XCTAssertEqual(reason.text.count, CallerStatedReason.maximumLength)
        XCTAssertTrue(reason.truncated)
    }

    func testGet也支持reason() throws {
        let command = try GetCommand.parse(["cloudflare-billing", "api-token", "--reason", "核对账单"])
        XCTAssertEqual(command.statedReason()?.text, "核对账单")
    }

    /// 留言只是给人看的，不能影响任何判定：请求里带不带它，走的还是同一条授权路径。
    func testReason不参与拉起App的判定() throws {
        let withReason = ValueRequest(credentialId: "x", fieldName: "f", sessionId: nil,
                                      requestedFieldNames: ["f"],
                                      statedReason: CallerStatedReason(text: "一句话"))
        let without = ValueRequest(credentialId: "x", fieldName: "f", sessionId: nil, requestedFieldNames: ["f"])
        XCTAssertEqual(IPCLaunchPolicy.shouldLaunchApp(for: .value(withReason)),
                       IPCLaunchPolicy.shouldLaunchApp(for: .value(without)))
    }
}
