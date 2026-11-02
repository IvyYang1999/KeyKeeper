import ArgumentParser
import Foundation
import KeyKeeperCore

/// Legacy direct Keychain mutation is retired; only a read-only inventory remains.
struct MigrateStorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-storage",
        abstract: "Inspect the legacy storage migration plan (read-only)",
        discussion: """
        Direct storage migration and legacy-item deletion are retired because they \
        cannot safely coordinate with current credential storage. Use --dry-run to inspect field names \
        from an App-verified snapshot without fetching or changing values.
        """
    )

    @Flag(name: .long, help: "Only report what would be migrated; fetch and write nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Retired compatibility option; deletion is refused.")
    var deleteLegacy = false

    func run() throws {
        guard dryRun, !deleteLegacy else {
            throw CommandFailure("Direct storage migration and legacy-item deletion are retired. Use --dry-run for read-only inspection.")
        }
        let plan = MigrationExecutor.secretFields(in: try IPCClient.requestSnapshot().metadata)
        let fields = plan.reduce(0) { $0 + $1.fields.count }
        print("Found \(plan.count) credentials with \(fields) secret fields to migrate.")
        for entry in plan {
            print("  \(entry.credentialId): \(entry.fields.joined(separator: ", "))")
        }
        print("Dry run: nothing was fetched or written.")
    }
}

/// Pure orchestration, fully injectable so tests never touch IPC or the keychain.
struct MigrationExecutor {
    var loadMeta: () throws -> MetaFile
    var fetchValue: (_ credentialId: String, _ fieldName: String, _ allFields: [String]) throws -> String
    var store: KeychainBlobStore
    var deleteLegacyItem: (_ credentialId: String, _ fieldName: String) throws -> Void
    var log: (String) -> Void

    /// (credentialId, sorted secret field names) pairs, sorted by credential.
    static func secretFields(in meta: MetaFile) -> [(credentialId: String, fields: [String])] {
        meta.credentials
            .map { id, credential in
                (credentialId: id,
                 fields: credential.fields.filter(\.value.secret).map(\.key).sorted())
            }
            .filter { !$0.fields.isEmpty }
            .sorted { $0.credentialId < $1.credentialId }
    }

    func migrate(dryRun: Bool) throws {
        let plan = Self.secretFields(in: try loadMeta())
        let fieldCount = plan.reduce(0) { $0 + $1.fields.count }
        log("Found \(plan.count) credentials with \(fieldCount) secret fields to migrate.")

        if dryRun {
            for entry in plan {
                log("  \(entry.credentialId): \(entry.fields.joined(separator: ", "))")
            }
            log("Dry run: nothing was fetched or written.")
            return
        }

        log("Fetching values from the running KeyKeeper app (approve in its window if asked)…")
        var failures: [String] = []
        var migrated = 0
        for entry in plan {
            for field in entry.fields {
                do {
                    let value = try fetchValue(entry.credentialId, field, entry.fields)
                    try store.save(credentialId: entry.credentialId, fieldName: field, value: value)
                    // Verify through a fresh read before counting it as migrated.
                    guard try store.retrieve(credentialId: entry.credentialId, fieldName: field) == value else {
                        failures.append("\(entry.credentialId).\(field): verification mismatch")
                        continue
                    }
                    migrated += 1
                    log("  ✓ \(entry.credentialId).\(field)")
                } catch {
                    failures.append("\(entry.credentialId).\(field): \(error.localizedDescription)")
                    log("  ✗ \(entry.credentialId).\(field)")
                }
            }
        }

        log("Migrated and verified \(migrated)/\(fieldCount) fields.")
        if !failures.isEmpty {
            log("Failed:")
            failures.forEach { log("  \($0)") }
            log("Fix the failures (approve the caller, or re-enter the value in the app) and run again; already-migrated fields are simply overwritten with the same value.")
            throw ExitCode(1)
        }
        log("Done. Legacy items were left in place; run with --delete-legacy after verifying the new app works.")
    }

    func deleteLegacyItems() throws {
        let plan = Self.secretFields(in: try loadMeta())
        var deleted = 0
        var missing = 0
        for entry in plan {
            for field in entry.fields {
                do {
                    try deleteLegacyItem(entry.credentialId, field)
                    deleted += 1
                } catch {
                    missing += 1
                }
            }
        }
        log("Deleted \(deleted) legacy keychain items (\(missing) were already gone).")
    }
}
