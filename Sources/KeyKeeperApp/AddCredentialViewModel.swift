import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var visible: Bool = false  // Hidden by default, click eye to reveal
    var existingSecret: Bool = false  // For detail view: whether this was loaded from Keychain
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    @Published var fields: [FieldEntry] = [FieldEntry()]
    @Published var security: SecurityLevel = .strict
    @Published var errorMessage: String?

    private let store = MetaStore.default
    private let keychain = KeychainService()

    var isValid: Bool {
        !label.isEmpty && fields.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    var hasDraft: Bool {
        !label.isEmpty || fields.contains { !$0.name.isEmpty || !$0.value.isEmpty }
    }

    func reset() {
        label = ""
        credentialId = ""
        notes = ""
        fields = [FieldEntry()]
        security = .strict
        errorMessage = nil
        previousAutoId = ""
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
            // All key values are secrets — stored in Keychain, never in meta.json
            try keychain.save(
                credentialId: credentialId, fieldName: field.name,
                value: field.value, security: security
            )
            credFields[field.name] = CredentialField(secret: true)
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = formatter.string(from: Date())

        meta.credentials[credentialId] = Credential(
            label: label, notes: notes,
            links: [],
            fields: credFields, security: security,
            created: now, updated: now
        )
        try store.save(meta)
    }
}
