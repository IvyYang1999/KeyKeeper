import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class AuthorizationDurationTests: XCTestCase {
    /// 【曾经的 bug】cron/IDE/SDK 调用没有终端会话，但授权窗默认选中「This session」，
    /// 用户过完 Touch ID 后窗口关闭、CLI 却收到 missingTerminalSession 拒绝。
    func test曾经的Bug无终端会话时不提供也不默认选中会话时长() {
        let options = AuthorizationView.DurationOption.available(hasTerminalSession: false)
        XCTAssertFalse(options.contains(.session))
        XCTAssertEqual(options, [.once, .oneHour, .always])
        XCTAssertEqual(
            AuthorizationView.DurationOption.defaultSelection(hasTerminalSession: false),
            .oneHour
        )
    }

    func test有终端会话时提供并默认选中会话时长() {
        let options = AuthorizationView.DurationOption.available(hasTerminalSession: true)
        XCTAssertTrue(options.contains(.session))
        XCTAssertEqual(
            AuthorizationView.DurationOption.defaultSelection(hasTerminalSession: true),
            .session
        )
    }

    func test授权提示从请求推导是否有终端会话() {
        let withSession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: "w0t1p0:ABC", sessionLabel: "Terminal (w0t1p0:A)", pid: 1
        ))
        let withoutSession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: nil, sessionLabel: "Unknown terminal", pid: 1
        ))
        let emptySession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: "", sessionLabel: nil, pid: 1
        ))
        XCTAssertTrue(withSession.hasTerminalSession)
        XCTAssertFalse(withoutSession.hasTerminalSession)
        XCTAssertFalse(emptySession.hasTerminalSession)
    }
}
