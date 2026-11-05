import Foundation
import Darwin

public enum IdentityMigrationLegacyCapture {
    /// Fixed legacy sources only. No write or create call is reachable from this capture.
    public static func capture(fixture: IdentityMigrationFixture? = nil) throws -> IdentityMigrationSource {
        let directory = fixture?.directory ?? StorageIdentity.legacy.directory
        var info = stat()
        if lstat(directory.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
                  directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
                throw IdentityMigrationError.unavailable
            }
        } else if errno != ENOENT { throw IdentityMigrationError.unavailable }
        // These live files indicate that the old approval upgrade did not finish. Its audit
        // history must first enter the old protected document; do not silently abandon it.
        for name in ["grants.json", "service-grants.json"] {
            if try IdentityMigrationFiles.read(directory.appendingPathComponent(name)) != nil {
                throw IdentityMigrationError.unavailable
            }
        }
        let service = fixture?.service ?? StorageIdentity.legacy.credentialsService
        let journal = LocalVaultJournal(io: SecItemBlobIO(service: service + ".local-sync-journal", identity: .legacy),
            marker: FileLocalVaultJournalMarker(url: directory.appendingPathComponent("local-sync-journal.created")),
            namespace: LocalVaultJournal.namespace(service: service, directory: directory))
        try journal.requireReady()
        return try stableCapture {
            if FileManager.default.fileExists(atPath: directory.path) {
                try validateSourceFileNames(FileManager.default.contentsOfDirectory(atPath: directory.path))
            }
            func item(_ suffix: String) throws -> Data? {
                let name: String
                if let fixture {
                    let tail = suffix.hasPrefix("credentials.") ? String(suffix.dropFirst("credentials.".count)) : suffix
                    name = suffix == "credentials" ? fixture.service : fixture.service + "." + tail
                } else { name = StorageIdentity.legacy.servicePrefix + suffix }
                return try SecItemBlobIO(service: name, identity: .legacy).readBlobWithoutInteraction()
            }
            func file(_ name: String) throws -> Data? {
                try IdentityMigrationFiles.read(directory.appendingPathComponent(name))
            }
            func marker(_ name: String) throws -> Bool {
                guard let data = try file(name) else { return false }
                guard data == Data([1]) else { throw IdentityMigrationError.malformed }
                return true
            }
            guard let preferences = UserDefaults(suiteName: fixture?.service ?? StorageIdentity.legacy.rawValue) else { throw IdentityMigrationError.unavailable }
            return try .init(metadata: file("meta.json"), values: item("credentials"),
                integrityKey: item("metadata-mac"), approvals: item("credentials.approvals"),
                browserSessions: item("browser-sessions"), proposals: item("credentials.browser-import-proposals"),
                metadataHistory: file("metadata-changes.json"), preferences: IdentityMigrationPreferences.capture(from: preferences),
                browserMarker: marker("browser-store.created"), proposalMarker: marker("browser-import-proposals.created"))
        }
    }
    /// Before the person confirms anything: does the old KeyKeeper folder hold anything at all?
    /// File names and the folder's own attributes only. No file is opened and no Keychain item is
    /// queried, so no secret can be read here. An unexpected folder fails instead of meaning "empty".
    public static func legacyFilesExist(directory: URL = StorageIdentity.legacy.directory) throws -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw IdentityMigrationError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else {
            throw IdentityMigrationError.unavailable
        }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.path) }
        catch { throw IdentityMigrationError.unavailable }
        return names.contains { $0 != ".DS_Store" }
    }

    /// The caller holds the legacy endpoint lock for this whole operation. A direct legacy
    /// writer still changing any input makes the copy fail rather than activate mixed data.
    public static func stableCapture(read: () throws -> IdentityMigrationSource) throws -> IdentityMigrationSource {
        let first = try read(), second = try read()
        guard try first.encoded() == second.encoded() else { throw IdentityMigrationError.sourceChanged }
        _ = try first.prepared(allowUnsignedMetadata: true)
        return first
    }
    static func validateSourceFileNames(_ names: [String]) throws {
        let active: Set<String> = ["meta.json", "meta.json.lock", "metadata-changes.json", "metadata-changes.json.lock",
            "browser-store.created", "browser-import-proposals.created", "local-sync-journal.created", ".DS_Store"]
        for name in names where !active.contains(name) {
            // Already migrated grant archives are rollback records, not active state. They stay
            // at their original path together with the entire source directory.
            guard name.range(of: #"^(grants|service-grants)\.json\.migrated-[0-9]{4}-[0-9]{2}-[0-9]{2}$"#,
                             options: .regularExpression) != nil else { throw IdentityMigrationError.unavailable }
        }
    }
}
