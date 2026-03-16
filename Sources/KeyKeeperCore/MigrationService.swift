import Foundation

/// One-time migration: re-saves all keychain entries with permissive ACL
/// so that any KeyKeeper binary (CLI, App, debug, release) can access them
/// without per-app keychain prompts.
///
/// The first run WILL trigger per-app prompts (unavoidable for reading old entries).
/// After migration, all subsequent reads are prompt-free.
public enum MigrationService {
    private static let migrationKey = "keykeeper.aclMigrationV2"

    public static var isMigrationComplete: Bool {
        UserDefaults.standard.bool(forKey: migrationKey)
    }

    @discardableResult
    public static func migrateIfNeeded() -> Int {
        guard !isMigrationComplete else { return 0 }

        let store = MetaStore.default
        guard let meta = try? store.load() else { return 0 }
        let keychain = KeychainService()

        var totalFields = 0
        for (_, cred) in meta.credentials {
            totalFields += cred.fields.filter(\.value.secret).count
        }

        if totalFields > 0 {
            FileHandle.standardError.write(Data(
                "Updating keychain access for \(totalFields) entries (one-time)...\n".utf8
            ))
        }

        var migrated = 0
        for (credId, cred) in meta.credentials {
            for (fieldName, field) in cred.fields where field.secret {
                keychain.healAccess(credentialId: credId, fieldName: fieldName)
                migrated += 1
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)

        if migrated > 0 {
            FileHandle.standardError.write(Data(
                "Done. No more keychain prompts for future access.\n".utf8
            ))
        }
        return migrated
    }
}
