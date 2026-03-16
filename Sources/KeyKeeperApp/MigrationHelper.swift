import Foundation
import KeyKeeperCore

/// App-side wrapper around MigrationService.
/// Re-exports the core migration for backward compatibility.
enum MigrationHelper {
    static var isMigrationComplete: Bool {
        MigrationService.isMigrationComplete
    }

    @discardableResult
    static func migrateIfNeeded() -> Int {
        MigrationService.migrateIfNeeded()
    }
}
