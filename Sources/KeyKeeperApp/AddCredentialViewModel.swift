import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var isSecret: Bool = false
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    @Published var links: [String] = [""]
    @Published var fields: [FieldEntry] = [FieldEntry()]
    @Published var security: SecurityLevel = .standard

    private let store = MetaStore.default
    private let keychain = KeychainService()

    var isValid: Bool {
        !label.isEmpty && !credentialId.isEmpty && fields.contains { !$0.name.isEmpty }
    }

    func autoGenerateId() {
        if credentialId.isEmpty || credentialId == previousAutoId {
            let newId = label
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            credentialId = newId
            previousAutoId = newId
        }
    }

    private var previousAutoId = ""

    func save() throws {
        var meta = try store.load()
        var credFields: [String: CredentialField] = [:]

        for field in fields where !field.name.isEmpty {
            if field.isSecret {
                try keychain.save(
                    credentialId: credentialId, fieldName: field.name,
                    value: field.value, security: security
                )
                credFields[field.name] = CredentialField(secret: true)
            } else {
                credFields[field.name] = CredentialField(value: field.value, secret: false)
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = formatter.string(from: Date())

        meta.credentials[credentialId] = Credential(
            label: label, notes: notes,
            links: links.filter { !$0.isEmpty },
            fields: credFields, security: security,
            created: now, updated: now
        )
        try store.save(meta)
    }
}
