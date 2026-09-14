import Foundation
import KeyKeeperCore

/// The isolated instance an end-to-end run drives: a copy of the app pointed at its own data
/// directory, its own Keychain items and its own socket. Every switch here needs that full
/// triple; without it none of this exists, so a shipped binary carries no lever a stray
/// environment variable could pull on the real vault.
enum TestInstance {
    static let environment = ProcessInfo.processInfo.environment

    /// True only when the credential store itself resolved to a test Keychain item — the same
    /// check the store, the socket and the session store all make.
    static let isIsolated: Bool = isIsolated(environment: environment)

    static func isIsolated(environment: [String: String]) -> Bool {
        (try? SecItemBlobIO.serviceName(environment: environment))?.hasPrefix("com.keykeeper.test.") == true
    }

    /// Answer every approval prompt without a person, with this duration. The e2e script sets it;
    /// the prompts themselves never appear.
    enum AutoApprove: String {
        case once, always

        var duration: ApprovalDuration {
            switch self {
            case .once: return .once
            case .always: return .always
            }
        }
    }

    static let autoApprove: AutoApprove? = autoApprove(environment: environment)

    static func autoApprove(environment: [String: String]) -> AutoApprove? {
        guard isIsolated(environment: environment) else { return nil }
        return environment["KEYKEEPER_TEST_AUTO_APPROVE"].flatMap(AutoApprove.init(rawValue:))
    }

    /// Delete this instance's Keychain items when it quits, so a test run leaves nothing behind.
    static let cleansUpOnQuit: Bool = isIsolated && environment["KEYKEEPER_TEST_CLEANUP_ON_QUIT"] == "1"

    /// Every Keychain item an isolated instance can create.
    static func ownedKeychainServices(environment: [String: String]) -> [String] {
        guard isIsolated(environment: environment) else { return [] }
        var services: [String] = []
        if let credentials = try? SecItemBlobIO.serviceName(environment: environment) { services.append(credentials) }
        if let sessions = try? BrowserSessionStore.serviceName(environment: environment) { services.append(sessions) }
        if let approvals = try? ApprovalStore.serviceName(environment: environment) { services.append(approvals) }
        services.append(IntegrityKeyNames.service("metadata-mac", environment: environment))
        return services.filter { $0.hasPrefix("com.keykeeper.test.") }
    }

    static func cleanUpKeychain() {
        for service in ownedKeychainServices(environment: environment) {
            try? SecItemBlobIO(service: service).deleteItem()
        }
    }
}
