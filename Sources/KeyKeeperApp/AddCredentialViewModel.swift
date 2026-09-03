import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var visible: Bool = false  // Hidden by default, click eye to reveal
    var existingSecret: Bool = false  // For detail view: whether this value already exists in the vault
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    @Published var fields: [FieldEntry] = [FieldEntry()]
    @Published var security: SecurityLevel = SecurityLevelPresentation.defaultLevel
    @Published var errorMessage: String?
    /// IDs already in the metadata store, so a duplicate is caught before it overwrites.
    @Published private(set) var existingIds: Set<String> = []

    private let session: any CredentialSessionManaging
    private let store: MetaStore

    init(session: any CredentialSessionManaging, store: MetaStore = .default) {
        self.session = session
        self.store = store
        refreshExistingIds()
    }

    var isValid: Bool {
        !label.isEmpty
            && idProblem == nil
            && fields.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    var hasDraft: Bool {
        !label.isEmpty || fields.contains { !$0.name.isEmpty || !$0.value.isEmpty }
    }

    /// Shown in the list's "continue draft" hint.
    var draftTitle: String {
        label.isEmpty ? "(untitled)" : label
    }

    /// Why the current ID can't be saved, or nil when it is fine.
    var idProblem: String? {
        if credentialId.isEmpty {
            return "Add letters or numbers to the name, or type an ID."
        }
        if credentialId != Self.sanitizeId(credentialId) {
            return "IDs can only use lowercase letters, numbers and dashes."
        }
        if existingIds.contains(credentialId) {
            return "A credential with ID \u{201C}\(credentialId)\u{201D} already exists. Pick another ID or edit the existing one."
        }
        return nil
    }

    func refreshExistingIds() {
        existingIds = Set((try? store.load())?.credentials.keys ?? [:].keys)
    }

    func reset() {
        label = ""
        credentialId = ""
        notes = ""
        fields = [FieldEntry()]
        security = SecurityLevelPresentation.defaultLevel
        errorMessage = nil
        previousAutoId = ""
        refreshExistingIds()
    }

    func autoGenerateId() {
        if credentialId.isEmpty || credentialId == previousAutoId {
            let newId = Self.sanitizeId(label)
            credentialId = newId
            previousAutoId = newId
        }
    }

    /// Applied while the user edits the ID field directly.
    func userEditedId(_ raw: String) {
        let cleaned = Self.sanitizeId(raw)
        if cleaned != credentialId {
            credentialId = cleaned
        }
    }

    static func sanitizeId(_ raw: String) -> String {
        raw
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            .replacing(#/-{2,}/#, with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private var previousAutoId = ""

    @discardableResult
    func save() -> Bool {
        do {
            try CredentialOperationMessages.requireUnlocked(session)
            var meta = try store.load()
            let existingFields = meta.credentials[credentialId]?.fields ?? [:]
            let plan = CredentialEditPlan(
                inputFields: fields.map { .init(name: $0.name, value: $0.value) },
                existingFields: existingFields,
                security: security
            )

            for fieldName in plan.valueDeletions {
                try session.delete(credentialId: credentialId, fieldName: fieldName)
            }
            for write in plan.valueWrites {
                try session.save(
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
            errorMessage = nil
            refreshExistingIds()
            return true
        } catch {
            errorMessage = CredentialOperationMessages.failure(
                action: "save this credential",
                fallbackPrefix: "Save failed",
                error: error
            )
            return false
        }
    }
}
