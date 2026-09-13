import XCTest
@testable import KeyKeeperApp

/// 【独立审计 2026-09-13】认不出的调用方，KeyKeeper 记不住给它的授权，授权窗却照样提供「1 小时」「始终允许」。
@MainActor
final class UnverifiedDurationTests: XCTestCase {
    func test认不出的调用方只提供仅这一次() {
        XCTAssertEqual(AuthorizationView.DurationOption.available(hasTerminalSession: true, canRemember: false), [.once])
        XCTAssertEqual(AuthorizationView.DurationOption.defaultSelection(hasTerminalSession: true, canRemember: false), .once)
        XCTAssertEqual(AuthorizationView.DurationOption.available(hasTerminalSession: false), [.once, .oneHour, .always])
        XCTAssertFalse(CallerAssurance.unverified.canRemember)
        XCTAssertTrue(CallerAssurance.unsigned.canRemember)
    }

    func testService授权窗对认不出的调用方收起长期选项() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AuthorizationView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(view.range(of: "private var serviceButtons"))
        XCTAssertTrue(view[start.upperBound...].contains("if callerAssurance.canRemember {"))
    }
}
