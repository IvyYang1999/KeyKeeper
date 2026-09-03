import Foundation
import KeyKeeperCore

@MainActor
class CredentialListViewModel: ObservableObject {
    @Published var credentials: [(id: String, credential: Credential)] = []
    @Published var searchText = ""
    @Published var errorMessage: String?

    private let session: any CredentialSessionManaging
    private let store: MetaStore

    init(session: any CredentialSessionManaging, store: MetaStore = .default) {
        self.session = session
        self.store = store
    }

    var filtered: [(id: String, credential: Credential)] {
        if searchText.isEmpty { return credentials }
        return credentials.filter {
            $0.id.localizedCaseInsensitiveContains(searchText) ||
            $0.credential.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    func load() {
        guard let meta = try? store.load() else { return }
        credentials = meta.credentials
            .sorted { $0.value.updated > $1.value.updated }
            .map { (id: $0.key, credential: $0.value) }
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
                action: "delete this credential",
                fallbackPrefix: "Delete failed",
                error: error
            )
            return false
        }
    }
}
