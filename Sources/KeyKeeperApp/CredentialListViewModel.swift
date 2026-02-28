import Foundation
import KeyKeeperCore

@MainActor
class CredentialListViewModel: ObservableObject {
    @Published var credentials: [(id: String, credential: Credential)] = []
    @Published var searchText = ""

    private let store = MetaStore.default

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
            .sorted { $0.key < $1.key }
            .map { (id: $0.key, credential: $0.value) }
    }

    func delete(id: String) {
        guard var meta = try? store.load() else { return }
        let cred = meta.credentials[id]
        let keychain = KeychainService()
        for (fieldName, field) in cred?.fields ?? [:] where field.secret {
            try? keychain.delete(credentialId: id, fieldName: fieldName)
        }
        meta.credentials.removeValue(forKey: id)
        try? store.save(meta)
        load()
    }
}
