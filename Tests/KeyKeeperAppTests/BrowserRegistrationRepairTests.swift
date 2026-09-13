import XCTest
@testable import KeyKeeperApp

/// 【独立审计 2026-09-13】注册文件被改过时，界面上唯一的按钮「注册」是只建不覆盖的——文件已经在，
/// 它必然失败，被篡改的注册于是修不回来。被改过的，就得覆盖。
final class BrowserRegistrationRepairTests: XCTestCase {
    func test被改过的注册文件点注册会覆盖() {
        XCTAssertTrue(BrowserExtensionSetup.registrationReplacesExisting(.tamperedWith))
        XCTAssertFalse(BrowserExtensionSetup.registrationReplacesExisting(.notRegistered))
    }
}
