import Foundation
import KeyKeeperCore

struct FieldEntry: Identifiable {
    let id = UUID()
    var name: String = ""
    var value: String = ""
    var visible: Bool = false  // Hidden by default, click eye to reveal
    var existingSecret: Bool = false  // For detail view: whether this value already exists in the keychain store
    var fileFormat: CredentialFileFormat?
    /// Name at the time editing started (detail view only), so a rename keeps the stored value.
    var originalName: String?
    /// Free-text label for people and agents (detail editor only; on Add the typed name is it).
    var displayName: String = ""
    /// A plain value a caller wrote over the socket that nobody has confirmed yet (detail view).
    var setByCaller: String?
    /// False for plain metadata (an account id, a region, an email): the value is stored in
    /// meta.json in the clear and injected without asking anyone.
    var isSecret: Bool = true
}

@MainActor
class AddCredentialViewModel: ObservableObject {
    @Published var label = ""
    @Published var credentialId = ""
    @Published var notes = ""
    /// Last day the key works at its provider, YYYY-MM-DD; nil when the person did not record one.
    @Published var expires: String?
    @Published var fields: [FieldEntry] = [FieldEntry(name: AddCredentialViewModel.defaultFieldName)]
    @Published var security: SecurityLevel = SecurityLevelPresentation.defaultLevel
    @Published var errorMessage: String?
    /// A service-account JSON chosen instead of typed values. Saved through the confirmed
    /// file import (the App reads it only after approval), never read by this form.
    @Published var sourceFile: URL?
    /// Set when the first value came from the clipboard, so a successful save can clear it.
    @Published var clipboardChangeCount: Int?
    /// IDs already in the metadata store, so a duplicate is caught before it overwrites.
    @Published private(set) var existingIds: Set<String> = []

    private let session: any CredentialSessionManaging
    private let store: MetaStore

    private let approvals: ApprovalStore

    init(session: any CredentialSessionManaging, store: MetaStore = .default, approvals: ApprovalStore) {
        self.session = session
        self.store = store
        self.approvals = approvals
        refreshExistingIds()
    }

    /// Pre-filled for the first key: an overwhelming majority of credentials have exactly
    /// one field called this, and asking for it is a decision the beginner cannot make yet.
    static let defaultFieldName = "api-key"

    var isValid: Bool {
        if sourceFile != nil { return !label.isEmpty && idProblem == nil }
        return !label.isEmpty
            && idProblem == nil
            && fields.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    /// A pristine form is not a draft — the pre-filled default key name must not by itself
    /// make the list show a "continue editing draft" chip.
    var hasDraft: Bool {
        if !label.isEmpty || !notes.isEmpty || sourceFile != nil { return true }
        if fields.count > 1 { return true }
        guard let only = fields.first else { return false }
        if !only.value.isEmpty { return true }
        return !only.name.isEmpty && only.name != Self.defaultFieldName
    }

    /// The gray line under the Name field: what scripts and AI tools will actually type.
    var idSummary: String {
        credentialId.isEmpty
            ? L("The ID is created from the name")
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
            return L("Add letters or numbers to the name, or type an ID.")
        }
        if !CredentialNames.isValidGroupId(credentialId) {
            return L("IDs can only use lowercase letters, numbers and dashes.")
        }
        return nil
    }

    /// Shown in the list's "continue draft" hint.
    var draftTitle: String {
        label.isEmpty ? L("(untitled)") : label
    }

    /// Why the current ID can't be saved, or nil when it is fine.
    var idProblem: String? {
        if let idFormatProblem { return idFormatProblem }
        if let conflictingId {
            return L("A credential with ID \u{201C}\(conflictingId)\u{201D} already exists. Pick another ID or edit the existing one.")
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
        expires = nil
        fields = [FieldEntry(name: Self.defaultFieldName)]
        security = SecurityLevelPresentation.defaultLevel
        errorMessage = nil
        sourceFile = nil
        clipboardChangeCount = nil
        previousAutoId = ""
        refreshExistingIds()
    }

    /// "From clipboard" in the menu bar: the user asked for this, so the text is read now
    /// and put into the first value box (still masked). The name is the only thing left to type.
    func prefillFromClipboard(_ value: String, changeCount: Int) {
        reset()
        fields = [FieldEntry(name: Self.defaultFieldName, value: value)]
        clipboardChangeCount = changeCount
    }

    /// "From file": remember the file and suggest a name from it; the contents are not read here.
    func useFile(_ url: URL) {
        sourceFile = url
        fields = [FieldEntry(name: Self.defaultFieldName)]
        if label.isEmpty {
            label = url.deletingPathExtension().lastPathComponent
        }
        autoGenerateId()
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

    /// Group IDs are for machines: plain ASCII, Chinese turned into pinyin ("百度千帆" →
    /// "bai-du-qian-fan"). The title keeps whatever the person wrote.
    static func sanitizeId(_ raw: String) -> String {
        CredentialNames.slug(raw)
    }

    /// The field name a machine uses for what the person typed: kept as is when it is already
    /// a valid name ("api_key", "API_KEY"), otherwise made plain ("API Key " → "api-key").
    /// What they typed is kept as the field's display name.
    static func machineFieldName(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if CredentialNames.isValidFieldName(trimmed) { return trimmed }
        let slug = CredentialNames.slug(trimmed)
        return slug.isEmpty ? "key" : slug
    }

    private var previousAutoId = ""

    @discardableResult
    func save() -> Bool {
        do {
            try CredentialOperationMessages.requireUnlocked(session)
            var meta = try store.load()
            guard meta.version == 1 else { throw ClipboardSaveError.storageUnavailable }
            guard meta.credentials[credentialId] == nil else { throw ClipboardSaveError.valueExists }
            guard !label.isEmpty, idFormatProblem == nil else { throw ClipboardSaveError.invalidTarget }
            // A new credential under a reused ID must not inherit what was given to the old one.
            guard try !approvals.hasApprovals(forCredential: credentialId) else { throw ClipboardSaveError.staleGrants }
            let named = fields.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
            let machineNames = named.map { Self.machineFieldName($0.name) }
            guard Set(machineNames).count == machineNames.count else { throw ClipboardSaveError.invalidTarget }
            if let reserved = machineNames.first(where: { EnvironmentVariableName.isReserved(fieldName: $0) }) {
                throw MetadataEditError.reservedFieldName(reserved)
            }
            var plan = CredentialEditPlan(
                inputFields: zip(named, machineNames).map { .init(name: $1, value: $0.value, isSecret: $0.isSecret) },
                existingFields: [:],
                security: security
            )
            for (entry, machine) in zip(named, machineNames) {
                let typed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if typed != machine { plan.metadata.fields[machine]?.displayName = typed }
            }
            var values: [String: String] = [:]
            for write in plan.valueWrites {
                guard values[write.fieldName] == nil else { throw ClipboardSaveError.invalidTarget }
                values[write.fieldName] = write.value
            }
            // A credential may hold nothing but plain fields (an account id and a team id, say);
            // then there is nothing to put in the Keychain and nothing to create there.
            guard !values.isEmpty || plan.metadata.fields.values.contains(where: { $0.value?.isEmpty == false }) else {
                throw ClipboardSaveError.invalidTarget
            }
            if !values.isEmpty {
                try session.createCredential(credentialId: credentialId, values: values, security: security)
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let now = formatter.string(from: Date())

            if !values.isEmpty { meta.storeInitialized = true }
            meta.credentials[credentialId] = Credential(
                label: label, notes: notes,
                links: [],
                fields: plan.metadata.fields, security: plan.metadata.security,
                created: now, updated: now, expires: expires
            )
            do { try store.save(meta) }
            catch { throw ClipboardSaveError.metadataCommitFailed }
            errorMessage = nil
            refreshExistingIds()
            return true
        } catch {
            errorMessage = CredentialOperationMessages.failure(
                action: L("save this credential"),
                fallbackPrefix: L("Save failed"),
                error: error
            )
            return false
        }
    }
}
