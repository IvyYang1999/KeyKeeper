import XCTest
@testable import KeyKeeperApp

final class StatusMenuBuilderTests: XCTestCase {
    func test菜单固定包含手动检查更新且无锁相关项() {
        let entries = StatusMenuBuilder.entries(launchAtLogin: true, launchAtLoginAvailable: false)
        XCTAssertEqual(entries, [
            .open,
            .checkForUpdates,
            .separator,
            .launchAtLogin(enabled: true, available: false),
            .settings,
            .separator,
            .quit,
        ])
    }
}
