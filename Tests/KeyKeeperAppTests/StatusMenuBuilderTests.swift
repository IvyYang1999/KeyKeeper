import XCTest
@testable import KeyKeeperApp

final class StatusMenuBuilderTests: XCTestCase {
    func test解锁态提供Lock锁定态提供Unlock无vault提供Create() {
        XCTAssertTrue(StatusMenuBuilder.entries(state: .unlocked(expiresAt: nil), launchAtLogin: false, launchAtLoginAvailable: true).contains(.lock))
        XCTAssertTrue(StatusMenuBuilder.entries(state: .locked, launchAtLogin: false, launchAtLoginAvailable: true).contains(.unlock))
        XCTAssertTrue(StatusMenuBuilder.entries(state: .needsVault, launchAtLogin: false, launchAtLoginAvailable: true).contains(.createVault))
        XCTAssertFalse(StatusMenuBuilder.entries(state: .locked, launchAtLogin: false, launchAtLoginAvailable: true).contains(.lock))
    }

    func test菜单始终包含打开设置与退出且反映开机自启状态() {
        let entries = StatusMenuBuilder.entries(state: .locked, launchAtLogin: true, launchAtLoginAvailable: false)
        XCTAssertEqual(entries.first, .open)
        XCTAssertEqual(entries.last, .quit)
        XCTAssertTrue(entries.contains(.settings))
        XCTAssertTrue(entries.contains(.launchAtLogin(enabled: true, available: false)))
    }
}
