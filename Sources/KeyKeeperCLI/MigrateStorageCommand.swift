import ArgumentParser
import Foundation
import KeyKeeperCore

/// One-time migration from the legacy per-field keychain items to the single-blob
/// store (decision 2026-09-03, 方案-20260903-去passphrase化 option A).
///
/// Values are fetched over IPC from the RUNNING production app, whose signature is the
/// one the legacy items' ACLs already trust — so the export itself triggers no system
/// keychain prompts. Approvals in KeyKeeper's own window may still appear, exactly as
/// for any caller. Secret values never touch stdout, files, or the process arguments.
struct MigrateStorageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate-storage",
        abstract: "Copy legacy per-field keychain values into the single-item store",
        discussion: """
        Run this ONCE, by hand, while the old KeyKeeper app is still running. Then \
        install the new app. The first time the new app reads the migrated store, \
        macOS asks once; click "Always Allow" and it never asks again.

        Legacy items are left in place as a safety net. After verifying that \
        everything works, remove them with --delete-legacy.
        """
    )

    @Flag(name: .long, help: "Only report what would be migrated; fetch and write nothing.")
    var dryRun = false

    @Flag(name: .long, help: "Delete the legacy per-field keychain items (run only after verifying the migration).")
    var deleteLegacy = false

    func run() throws {
        let session = SessionResolver.resolve()
        let executor = MigrationExecutor(
            loadMeta: { try MetaStore.default.load() },
            fetchValue: { credentialId, fieldName, allFields in
                try IPCClient.requestValue(
                    credentialId: credentialId,
                    fieldName: fieldName,
                    sessionId: session.id,
                    requestedFieldNames: allFields
                )
            },
            store: KeychainBlobStore(),
            deleteLegacyItem: { credentialId, fieldName in
                try KeychainService().delete(credentialId: credentialId, fieldName: fieldName)
            },
            log: { print($0) }
        )

        if deleteLegacy {
            try executor.deleteLegacyItems()
        } else {
            try executor.migrate(dryRun: dryRun)
        }
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
