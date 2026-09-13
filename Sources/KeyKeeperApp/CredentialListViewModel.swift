import Foundation
import KeyKeeperCore

@MainActor
class CredentialListViewModel: ObservableObject {
    @Published var credentials: [(id: String, credential: Credential)] = []
    @Published var searchText = ""
    @Published var errorMessage: String?
    @Published private(set) var valueAvailability: [String: CredentialValueAvailability] = [:]
    @Published private(set) var isCheckingValues = false
    private var inspectionGeneration = 0
    /// Set when meta.json exists but cannot be read. Distinct from "no credentials yet":
    /// a secrets manager must never tell the user their data is gone when a file is merely unreadable.
    @Published private(set) var loadFailure: LoadFailure?
    /// meta.json no longer carries KeyKeeper's signature: something else wrote it, so which fields
    /// are secret and what the plain values say are unproven.
    ///
    /// 【安全遗留 2026-09-13】the CLI already stopped trusting a tampered file; the app showed
    /// nothing, so agents just failed and nobody could tell why or put it right. The way back is
    /// for the person to look, prove they are at the Mac, and let KeyKeeper sign what they saw.
    @Published private(set) var metadataTampered = false
    /// Injected by tests; production asks for Touch ID or the device password.
    var confirmOwner: (_ reason: String, _ reply: @escaping (Bool) -> Void) -> Void = DeviceOwnerCheck.confirm

    struct LoadFailure: Equatable {
        let fileURL: URL
        let reason: String
    }

    private let session: any CredentialSessionManaging
    private let store: MetaStore

    init(session: any CredentialSessionManaging, store: MetaStore = .default) {
        self.session = session
        self.store = store
    }

    var filtered: [(id: String, credential: Credential)] {
        if searchText.isEmpty { return credentials }
        return credentials.filter { Self.matches(id: $0.id, credential: $0.credential, query: searchText) }
    }

    /// Matches what the row shows: id, label, notes and key names (plus the env var
    /// names those keys become), so searching "API_KEY" finds the credential that has it.
    static func matches(id: String, credential: Credential, query: String) -> Bool {
        let haystack = [id, credential.label, credential.notes]
            + credential.fields.keys.map { $0 }
            + credential.fields.keys.map { EnvironmentVariableName.from(fieldName: $0) }
        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Newest first; ties (same day) fall back to label, then id, so the order never jumps between loads.
    static func sorted(_ entries: [(id: String, credential: Credential)]) -> [(id: String, credential: Credential)] {
        entries.sorted { lhs, rhs in
            if lhs.credential.updated != rhs.credential.updated {
                return lhs.credential.updated > rhs.credential.updated
            }
            let byLabel = lhs.credential.label.localizedCaseInsensitiveCompare(rhs.credential.label)
            if byLabel != .orderedSame {
                return byLabel == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    func load() {
        inspectionGeneration += 1
        valueAvailability = [:]
        do {
            let meta = try store.load()
            credentials = Self.sorted(meta.credentials.map { (id: $0.key, credential: $0.value) })
            loadFailure = nil
            metadataTampered = (try? store.loadVerified().verdict) == .tampered
            checkValues()
        } catch {
            credentials = []
            loadFailure = LoadFailure(fileURL: store.fileURL, reason: error.localizedDescription)
        }
    }

    /// The person has looked at the list and vouches for it: sign exactly what is on disk now.
    func trustCurrentMetadata() {
        confirmOwner(L("confirm that the credential list is correct")) { [weak self] approved in
            MainActor.assumeIsolated {
                guard let self, approved else { return }
                do {
                    try self.store.save(try self.store.load())
                    self.load()
                } catch {
                    self.errorMessage = L("Could not confirm the list: \(error.localizedDescription)")
                }
            }
        }
    }

    /// One in-flight read per model; reloads coalesce and stale results are discarded.
    private func checkValues() {
        guard !isCheckingValues, !credentials.isEmpty, loadFailure == nil else { return }
        isCheckingValues = true
        let generation = inspectionGeneration
        let probe = ValueInventoryProbe(session: session)
        Task { [weak self] in
            let inventory = await Task.detached(priority: .utility) { probe.read() }.value
            guard let self else { return }
            self.isCheckingValues = false
            guard generation == self.inspectionGeneration else {
                self.checkValues()
                return
            }
            self.valueAvailability = Dictionary(uniqueKeysWithValues: self.credentials.map { item in
                (item.id, inventory.map {
                    CredentialValueAvailability.check(item.credential, presentFields: $0[item.id] ?? [])
                } ?? .init(state: .unavailable))
            })
        }
    }

    @discardableResult
    func delete(id: String) -> Bool {
        do {
            try CredentialOperationMessages.requireUnlocked(session)
            var meta = try store.load()
            guard let credential = meta.credentials[id] else { return false }

            let secretFieldNames = credential.fields
                .filter { $0.value.secret }
                .map(\.key)
                .sorted()

            // Completeness is judged for this credential only, as the editor does: one credential
            // that lost its value must not make every other credential undeletable. This one's own
            // record stays protected while a value is missing — it is the trail back to what went
            // missing. A store that cannot be read at all still blocks: storedFieldNames throws.
            do {
                let stored = try session.storedFieldNames(credentialId: id)
                guard Set(secretFieldNames).isSubset(of: stored) else {
                    throw CredentialStorageError.incompleteStore
                }
            } catch let error as ClipboardSaveError where error == .storageUnavailable {
                // A session that cannot enumerate its store: keep the whole-store check.
                try CredentialOperationMessages.requireWritableStorage(session)
            }
            for fieldName in secretFieldNames {
                try session.delete(credentialId: id, fieldName: fieldName)
            }

            meta.credentials.removeValue(forKey: id)
            try store.save(meta)
            load()
            errorMessage = nil
            return true
        } catch {
            errorMessage = CredentialOperationMessages.failure(
                action: L("delete this credential"),
                fallbackPrefix: L("Delete failed"),
                error: error
            )
            return false
        }
    }
}

/// Production session owns a locked store. The task returns names only, never values.
private final class ValueInventoryProbe: @unchecked Sendable {
    let session: any CredentialSessionManaging
    init(session: any CredentialSessionManaging) { self.session = session }
    func read() -> [String: Set<String>]? { try? session.inspectValueInventory() }
}
