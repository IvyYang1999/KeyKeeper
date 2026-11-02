import Foundation

/// Shipping code can construct only the fixed production scope. Acceptance builds
/// derive both cloud and keychain names from one required UUID; no string override.
enum CloudSyncScope: Sendable {
    case production
    #if KEYKEEPER_SYNC_ACCEPTANCE
    case acceptance(UUID)
    #endif

    var zoneName: String {
        switch self {
        case .production: return "KeyKeeperVault-v1"
        #if KEYKEEPER_SYNC_ACCEPTANCE
        case .acceptance(let id): return "KeyKeeperProductAcceptance-" + id.uuidString
        #endif
        }
    }
    var rootServicePrefix: String {
        switch self {
        case .production: return "dev.keykeeper.sync-root"
        #if KEYKEEPER_SYNC_ACCEPTANCE
        case .acceptance(let id): return "dev.keykeeper.test.sync-root." + id.uuidString
        #endif
        }
    }
}
