#if KEYKEEPER_SYNC_ACCEPTANCE
import Foundation
import Darwin

/// Compiled only for the separately signed acceptance executable. Every local item
/// is a nonsynchronizable current-identity DP item; no production resolver is used.
public struct CloudSyncAcceptanceStores {
    public let local: LocalVaultCommitCoordinator
    public let stateStore: CloudSyncStateStore
    public let approvals: ApprovalStore

    public static func open(runID: UUID, clientID: UUID, initializeIfAbsent: Bool) throws -> Self {
        try open(runID: runID, clientID: clientID, initializeIfAbsent: initializeIfAbsent,
            ioFactory: { SecItemBlobIO(service: $0, identity: .current) },
            verifyIdentity: { _ = try CloudSyncNativeIdentity.current() })
    }

    /// Internal syscall-free test seam. The public constructor always validates the
    /// real signature and creates real, explicitly current-identity Keychain IO.
    static func open(runID: UUID, clientID: UUID, initializeIfAbsent: Bool,
                     ioFactory: (String) -> KeychainBlobIO, verifyIdentity: () throws -> Void) throws -> Self {
        let directory = try admittedDirectory(runID: runID, clientID: clientID)
        try verifyIdentity()
        let prefix = "dev.keykeeper.test.product-sync.\(runID.uuidString).\(clientID.uuidString)"
        let values = ioFactory(prefix + ".values"), integrity = ioFactory(prefix + ".metadata-mac")
        let grants = ioFactory(prefix + ".approvals"), journalIO = ioFactory(prefix + ".local-sync-journal")
        let stateIO = ioFactory(prefix + ".cloud-sync-state")
        let ready = FileLocalVaultJournalMarker(url: directory.appendingPathComponent("acceptance-vault.created"))
        let journalMarker = FileLocalVaultJournalMarker(url: directory.appendingPathComponent("local-sync-journal.created"))
        let stateMarker = FileLocalVaultJournalMarker(url: directory.appendingPathComponent("cloud-sync-state.created"))
        let metadataExists = try existingRegularFile(directory.appendingPathComponent("meta.json"))
        let existing = try [values, integrity, grants, journalIO, stateIO].map { try $0.readBlobWithoutInteraction() }
        let meta = MetaStore(directory: directory, integrityIO: integrity)
        if try ready.wasCreated() {
            guard metadataExists, existing.prefix(3).allSatisfy({ $0 != nil }) else { throw CloudSyncError.stateUnavailable }
        } else {
            // Interrupted initialization is retained for inspection, never silently
            // reclassified as a fresh vault or repaired by overwriting an item.
            guard initializeIfAbsent, !metadataExists, existing.allSatisfy({ $0 == nil }),
                  try !journalMarker.wasCreated(), try !stateMarker.wasCreated() else { throw CloudSyncError.stateUnavailable }
            let emptyValues = try CloudVaultSnapshot.encode(KeychainBlobStore.Blob.empty)
            let emptyGrants = try CloudVaultSnapshot.encode(ApprovalDocument())
            try meta.save(.init(storeInitialized: true, credentials: [:]))
            try values.writeBlob(emptyValues, replacingExisting: false)
            try grants.writeBlob(emptyGrants, replacingExisting: false)
            guard try meta.loadVerified().verdict == .intact,
                  try values.readBlobWithoutInteraction() == emptyValues,
                  try grants.readBlobWithoutInteraction() == emptyGrants else { throw CloudSyncError.stateUnavailable }
            try ready.markCreated()
            guard try ready.wasCreated() else { throw CloudSyncError.stateUnavailable }
        }
        let namespace = LocalVaultJournal.namespace(service: prefix + ".values", directory: directory)
        let journal = LocalVaultJournal(io: journalIO, marker: journalMarker, namespace: namespace)
        let gate = VaultAccessGate { try journal.requireReady() }
        let adapter = LocalVaultCommitAdapter(metaStore: meta, valuesIO: values, integrityIO: integrity,
            approvalsIO: grants, namespace: namespace)
        // Opening never performs recovery. inspect stays read-only; an explicit
        // operational command can call local.recover() before using the coordinator.
        return .init(local: .init(adapter: adapter, journal: journal, gate: gate),
            stateStore: .init(io: stateIO, marker: stateMarker, namespace: namespace),
            approvals: .init(io: grants, accessGate: gate))
    }

    static func admittedDirectory(runID: UUID, clientID: UUID) throws -> URL {
        let name = "/private/tmp/keykeeper-product-sync-\(runID.uuidString)-\(clientID.uuidString)"
        guard let pointer = realpath(name, nil) else { throw CloudSyncError.setupRequired }
        defer { free(pointer) }
        var info = stat()
        guard String(cString: pointer) == name, lstat(name, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else { throw CloudSyncError.setupRequired }
        let directory = URL(fileURLWithPath: name, isDirectory: true)
        for file in ["meta.json", "acceptance-vault.created", "local-sync-journal.created", "cloud-sync-state.created"] {
            _ = try existingRegularFile(directory.appendingPathComponent(file))
        }
        return directory
    }

    private static func existingRegularFile(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return false }
            throw CloudSyncError.setupRequired
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1 else {
            throw CloudSyncError.setupRequired
        }
        return true
    }
}
#endif
