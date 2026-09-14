import Foundation
import KeyKeeperCore

/// What the app does to its stores at every launch, in one place, so a test can run exactly this
/// over files written by an earlier version.
///
/// 【曾经的 bug · 2026-09-13】the launch-time prunes ran straight from AppDelegate, and the first
/// launch after an upgrade wiped every background approval: nobody had ever run the launch
/// sequence over an old data directory before shipping it.
enum LaunchMaintenance {
    struct Stores {
        var meta: MetaStore
        var inventory: () throws -> [String: Set<String>]
        var approvals: ApprovalStore
        /// Where earlier versions kept grants.json / service-grants.json.
        var directory: URL
        var sessionStore: BrowserSessionStore?
    }

    static func run(_ stores: Stores) {
        // Approvals from the files earlier versions wrote move into the Keychain item, once.
        _ = try? ApprovalMigration.runIfNeeded(directory: stores.directory, store: stores.approvals,
                                               sessionGrants: { try stores.sessionStore?.takeLegacyGrants() })
        // Record once that this machine has a Keychain store, so the "never recreate an empty
        // store" guard survives a vault whose fields are all plain at the moment. The inventory
        // is the non-interactive read: launch must never be able to raise a Keychain prompt.
        if let meta = try? stores.meta.load(),
           let updated = StoreInitializationMarker.updated(meta, inventory: stores.inventory) {
            try? stores.meta.save(updated)
        }
        // Expired and spent approvals grant nothing; they only clutter the list.
        try? stores.approvals.pruneExpired()
    }
}
