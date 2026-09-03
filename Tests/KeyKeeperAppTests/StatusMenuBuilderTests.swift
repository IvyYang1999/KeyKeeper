import XCTest
@testable import KeyKeeperApp

final class StatusMenuBuilderTests: XCTestCase {
    func test菜单固定为打开自启设置退出且无锁相关项() {
        let entries = StatusMenuBuilder.entries(launchAtLogin: true, launchAtLoginAvailable: false)
        XCTAssertEqual(entries, [
            .open,
            .separator,
            .launchAtLogin(enabled: true, available: false),
            .settings,
            .separator,
            .quit,
        ])
    }
}
