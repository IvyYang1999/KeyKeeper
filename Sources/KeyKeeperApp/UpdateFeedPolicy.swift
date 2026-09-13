import Foundation

/// Where updates are allowed to come from.
///
/// 【安全审计 2026-09-13】Sparkle reads its feed URL from user defaults if one is set there, and
/// a process running as this user can write that. The update would still have to carry a valid
/// signature, so nobody can install whatever they like — but they can serve an old feed forever,
/// which keeps someone on a version with a hole they already know about. The address compiled
/// into the bundle is the only one that counts.
enum UpdateFeedPolicy {
    static func pinnedFeedURL(bundleInfo: [String: Any]) -> String? {
        guard let value = bundleInfo["SUFeedURL"] as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil
        else { return nil }
        return value
    }

    static func pinnedFeedURL(bundle: Bundle = .main) -> String? {
        pinnedFeedURL(bundleInfo: bundle.infoDictionary ?? [:])
    }
}
