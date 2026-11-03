import XCTest
import AppKit
@testable import KeyKeeperApp

@MainActor
final class StatusButtonDispatchTests: XCTestCase {
    /// 【曾经的 bug】菜单栏按钮 target 为 nil，动作依赖未知 responder chain。
    func testConfiguredButtonDispatchesToItsOwningDelegate() throws {
        _ = NSApplication.shared
        guard !UpdateConfiguration(bundle: .main).canStartUpdater(isIsolated: TestInstance.isIsolated) else {
            return XCTFail("This offscreen test must not start Sparkle")
        }
        let owner = RecordingDelegate()
        let button = NSButton()
        owner.configureStatusButton(button)
        XCTAssertTrue(button.target === owner)
        let action = try XCTUnwrap(button.action)
        XCTAssertEqual(action, #selector(AppDelegate.togglePopover))
        XCTAssertEqual(owner.clicks, 0)
        XCTAssertTrue(NSApp.sendAction(action, to: button.target, from: button))
        XCTAssertEqual(owner.clicks, 1)
    }

    private final class RecordingDelegate: AppDelegate {
        var clicks = 0
        override func togglePopover() { clicks += 1 }
    }
}
