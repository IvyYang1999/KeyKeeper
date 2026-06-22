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
        let existingFields = meta.credentials[credentialId]?.fields ?? [:]
        let plan = CredentialEditPlan(
            inputFields: fields.map { .init(name: $0.name, value: $0.value) },
            existingFields: existingFields,
            security: security
        )

        for write in plan.keychainWrites {
            try keychain.save(
                credentialId: credentialId, fieldName: write.fieldName,
                value: write.value, security: plan.metadata.security
            )
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let now = formatter.string(from: Date())

        meta.credentials[credentialId] = Credential(
            label: label, notes: notes,
            links: [],
            fields: plan.metadata.fields, security: plan.metadata.security,
            created: now, updated: now
        )
        try store.save(meta)
    }
}
