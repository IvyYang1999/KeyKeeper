import XCTest
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-08 渲染发现：设置页重做后「再看一遍」挪到了「通用 · 欢迎指引」，
/// 首装引导底部还写着「之后可以在设置 → 命令行里重新打开引导」，指向一个已经没有它的地方。
@MainActor final class SetupReopenHintTests: XCTestCase {
    func test曾经的Bug引导底部指向设置里真正的位置() {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let hint = SetupView.reopenHint
            XCTAssertTrue(hint.contains(L("General")), "\(language): \(hint)")
            XCTAssertTrue(hint.contains(L("Welcome guide")), "\(language): \(hint)")
            XCTAssertFalse(hint.contains(L("Command line")), "\(language): \(hint)")
        }
    }
}
