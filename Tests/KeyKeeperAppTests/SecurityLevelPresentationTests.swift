import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class SecurityLevelPresentationTests: XCTestCase {
    func test默认安全等级是后台可用的standard() {
        XCTAssertEqual(SecurityLevelPresentation.defaultLevel, .standard)
    }

    func test文案不再把standard描述成不安全() {
        let standard = SecurityLevelPresentation.detail(.standard).lowercased()
        XCTAssertFalse(standard.contains("less secure"))
        XCTAssertFalse(standard.contains("risk"))
        XCTAssertTrue(standard.contains("cron"))
    }

    func test文案明确strict不适合无人值守() {
        let strict = SecurityLevelPresentation.detail(.strict).lowercased()
        XCTAssertTrue(strict.contains("cron"))
        XCTAssertTrue(strict.contains("not suitable"))
        XCTAssertFalse(strict.contains("touch id"))
    }

    func test每个等级都有独立徽标与图标() {
        XCTAssertNotEqual(
            SecurityLevelPresentation.badge(.standard),
            SecurityLevelPresentation.badge(.strict)
        )
        XCTAssertNotEqual(
            SecurityLevelPresentation.symbolName(.standard),
            SecurityLevelPresentation.symbolName(.strict)
        )
    }
}
