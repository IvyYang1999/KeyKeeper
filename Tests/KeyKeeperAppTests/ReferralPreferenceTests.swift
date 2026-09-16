import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

final class ReferralPreferenceTests: XCTestCase {
    func test默认开启关掉后记住且不影响列表顺序() {
        let defaults = UserDefaults(suiteName: "kk-referral-" + UUID().uuidString)!
        XCTAssertTrue(ReferralPreference.isEnabled(defaults))
        ReferralPreference.set(false, defaults)
        XCTAssertFalse(ReferralPreference.isEnabled(defaults))
        let names = ProviderBrowser.families.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, "品牌永远按名字排")
        for key in ["No account yet? Sign up", "Sign-up links", "Referral policy",
                    "Show a provider's referral sign-up link when adding a key"] {
            XCTAssertNotEqual(AppL10n.render(key, language: "zh-Hans"), key, key)
        }
    }
}
