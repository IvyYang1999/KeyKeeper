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
            checkValues()
        } catch {
            credentials = []
            loadFailure = LoadFailure(fileURL: store.fileURL, reason: error.localizedDescription)
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
            try CredentialOperationMessages.requireWritableStorage(session)
            var meta = try store.load()
            guard let credential = meta.credentials[id] else { return false }

            let secretFieldNames = credential.fields
                .filter { $0.value.secret }
                .map(\.key)
                .sorted()
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
