import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var visible: Bool = false  // Hidden by default, click eye to reveal
    var existingSecret: Bool = false  // For detail view: whether this value already exists in the keychain store
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    @Published var fields: [FieldEntry] = [FieldEntry(name: AddCredentialViewModel.defaultFieldName)]
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

    /// Pre-filled for the first key: an overwhelming majority of credentials have exactly
    /// one field called this, and asking for it is a decision the beginner cannot make yet.
    static let defaultFieldName = "api-key"

    var isValid: Bool {
        !label.isEmpty
            && idProblem == nil
            && fields.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    /// A pristine form is not a draft — the pre-filled default key name must not by itself
    /// make the list show a "continue editing draft" chip.
    var hasDraft: Bool {
        if !label.isEmpty || !notes.isEmpty { return true }
        if fields.count > 1 { return true }
        guard let only = fields.first else { return false }
        if !only.value.isEmpty { return true }
        return !only.name.isEmpty && only.name != Self.defaultFieldName
    }

    /// The gray line under the Name field: what scripts and AI tools will actually type.
    var idSummary: String {
        credentialId.isEmpty
            ? "The ID is created from the name"
            : "\(credentialId) \u{00B7} keykeeper run -c \(credentialId)"
    }

    /// Set when the derived ID is taken. Surfaced as an offer to open that credential
    /// rather than as an error, because the user has not done anything wrong.
    var conflictingId: String? {
        guard !credentialId.isEmpty, existingIds.contains(credentialId) else { return nil }
        return credentialId
    }

    /// Problems with the ID itself, as opposed to it already being taken.
    var idFormatProblem: String? {
        if credentialId.isEmpty {
            return "Add letters or numbers to the name, or type an ID."
        }
        if credentialId != Self.sanitizeId(credentialId) {
            return "IDs can only use lowercase letters, numbers and dashes."
        }
        return nil
    }

    /// Shown in the list's "continue draft" hint.
    var draftTitle: String {
        label.isEmpty ? "(untitled)" : label
    }

    /// Why the current ID can't be saved, or nil when it is fine.
    var idProblem: String? {
        if let idFormatProblem { return idFormatProblem }
        if let conflictingId {
            return "A credential with ID \u{201C}\(conflictingId)\u{201D} already exists. Pick another ID or edit the existing one."
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
        fields = [FieldEntry(name: Self.defaultFieldName)]
        security = SecurityLevelPresentation.defaultLevel
        errorMessage = nil
        previousAutoId = ""
        refreshExistingIds()
    }

    /// Fills the form from a `keykeeper://add` link. Replaces any draft: the link is a
    /// deliberate user action, and the values still have to be pasted by hand.
    func prefill(label: String?, fields fieldNames: [String], notes: String?) {
        reset()
        self.label = label ?? ""
        self.notes = notes ?? ""
        self.fields = fieldNames.isEmpty
            ? [FieldEntry(name: Self.defaultFieldName)]
            : fieldNames.map { FieldEntry(name: $0) }
        autoGenerateId()
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
