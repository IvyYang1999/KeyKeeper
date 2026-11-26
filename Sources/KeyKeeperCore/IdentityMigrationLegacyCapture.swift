import Foundation
import Darwin
import Security

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
                try SecItemBlobIO(service: itemService(suffix, fixture: fixture), identity: .legacy).readBlobWithoutInteraction()
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
    /// The old Keychain item for one capture suffix ("credentials", "metadata-mac", …).
    static func itemService(_ suffix: String, fixture: IdentityMigrationFixture?) -> String {
        guard let fixture else { return StorageIdentity.legacy.servicePrefix + suffix }
        let tail = suffix.hasPrefix("credentials.") ? String(suffix.dropFirst("credentials.".count)) : suffix
        return suffix == "credentials" ? fixture.service : fixture.service + "." + tail
    }

    /// Every old Keychain item that can hold a value, an approval, a cookie or a pasted key: what
    /// the person is told to delete once the copy is done. The capture reads exactly these, plus
    /// the old sync journal.
    public static func itemServices(fixture: IdentityMigrationFixture?) -> [String] {
        let suffixes = ["credentials", "metadata-mac", "credentials.approvals", "browser-sessions",
                        "credentials.browser-import-proposals"]
        let journal = (fixture?.service ?? StorageIdentity.legacy.credentialsService) + ".local-sync-journal"
        return suffixes.map { itemService($0, fixture: fixture) } + [journal]
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

/// Which items from before 0.3.7 are still in the person's keychains.
///
/// KeyKeeper does not delete them: the Keychain has no "delete only if unchanged", so a removal
/// could not guarantee it deletes only what was copied. The person deletes them in Keychain
/// Access; this tells them which names are left. Attributes only: no value is decrypted, no
/// item's access list is consulted, nothing is changed, and no dialog can appear.
public enum LegacyItemPresence {
    public static func remaining(services: [String] = IdentityMigrationLegacyCapture.itemServices(fixture: nil),
                                 present: (String) throws -> Bool = isPresent) throws -> [String] {
        try services.filter(present)
    }

    /// The person's keychain search list (no data-protection flag), the old item's fixed account.
    static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "keykeeper",
         kSecMatchLimit as String: kSecMatchLimitOne, kSecReturnAttributes as String: true,
         kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }

    public static func isPresent(_ service: String) throws -> Bool {
        var result: AnyObject?
        switch SecItemCopyMatching(query(service) as CFDictionary, &result) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw IdentityMigrationError.unavailable
        }
    }
}
