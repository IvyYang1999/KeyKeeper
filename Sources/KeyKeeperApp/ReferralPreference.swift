import Foundation
import SwiftUI
import KeyKeeperCore

/// Whether the app shows a provider's referral sign-up link next to "create the key at …".
/// On by default; a person who dislikes referral links turns it off once and never sees one.
/// A plain preference: it names no secret and steers no request.
enum ReferralPreference {
    static let key = "referralLinksEnabled"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
    static func set(_ enabled: Bool, _ defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}

/// "No account yet? Sign up ↗" with the disclosure on hover. Never shown without a signup
/// entry, never when the person turned referral links off.
struct ProviderSignupLink: View {
    let providerID: String?
    @AppStorage(ReferralPreference.key) private var enabled = true

    var body: some View {
        if enabled, let providerID, let template = ProviderCatalog.find(providerID),
           let signup = template.signup, let url = ProviderBrowser.safeWebURL(signup.url) {
            Link(destination: url) {
                HStack(spacing: 3) {
                    Text(L("No account yet? Sign up"))
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .font(.caption)
            }
            .help(signup.disclosure)
            .accessibilityIdentifier("provider-signup")
        }
    }
}
