import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【独立审计 2026-09-13】认不出的调用方拿不到可记住的授权，所以窗口只能给它「仅这一次」。
final class UnverifiedDurationTests: XCTestCase {
    func test认不出的调用方只提供仅这一次() {
        XCTAssertEqual(AuthorizationView.DurationChoice.available(canRemember: false, canBindToRun: true), [.once])
        XCTAssertEqual(AuthorizationView.DurationChoice.recommended(canRemember: false, canBindToRun: true, review: nil), .once)
        XCTAssertFalse(CallerAssurance.unverified.canRemember)
        XCTAssertTrue(CallerAssurance.unsigned.canRemember)
    }

    func test授权窗的按钮只画提供的那几档() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AuthorizationView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("ForEach(choices, id: \\.self)"))
        XCTAssertTrue(view.contains("DurationChoice.available(canRemember: callerAssurance.canRemember, canBindToRun: canBindToRun)"))
    }
}
