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
    /// Values only reach commands through `keykeeper run`; `get` and the SDKs are refused.
    @Published var injectOnly = true
    @Published var errorMessage: String?
    /// A service-account JSON chosen instead of typed values. Saved through the confirmed
    /// file import (the App reads it only after approval), never read by this form.
    @Published var sourceFile: URL?
    /// Set when the first value came from the clipboard, so a successful save can clear it.
    @Published var clipboardChangeCount: Int?
    @Published private(set) var providerID: String?
    @Published private(set) var providerFiles: [String: URL] = [:]
    private var providerFileSources: [String: CredentialFileSource] = [:]
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
        if providerID != nil {
            return !label.isEmpty && idProblem == nil && providerProblem == nil
        }
        if sourceFile != nil { return !label.isEmpty && idProblem == nil }
        return !label.isEmpty
            && idProblem == nil
            && fields.contains { !$0.name.isEmpty && !$0.value.isEmpty }
    }

    /// A pristine form is not a draft — the pre-filled default key name must not by itself
    /// make the list show a "continue editing draft" chip.
    var hasDraft: Bool {
        if providerID != nil { return true }
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
        providerID = nil
        providerFiles = [:]
        providerFileSources = [:]
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

    var provider: ProviderTemplate? { providerID.flatMap(ProviderCatalog.find) }

    /// No value is ever carried across contracts implicitly, including China/global variants.
    @discardableResult
    func selectProvider(_ id: String, discardValues: Bool = false) -> Bool {
        let next = id.isEmpty ? nil : ProviderCatalog.find(id)
        guard id.isEmpty || next != nil else { return false }
        if next?.id == providerID { return true }
        guard discardValues || !hasEnteredProviderValues else { return false }
        let oldName = provider?.name
        providerID = next?.id
        providerFiles = [:]
        providerFileSources = [:]
        sourceFile = nil
        clipboardChangeCount = nil
        fields = next?.fields.map {
            FieldEntry(name: $0.name, fileFormat: $0.fileFormat,
                       displayName: $0.label, isSecret: $0.isSaveableSecret)
        } ?? [FieldEntry(name: Self.defaultFieldName)]
        if label.isEmpty || label == oldName {
            label = next?.name ?? ""
            autoGenerateId()
        }
        errorMessage = nil
        return true
    }

    var hasEnteredProviderValues: Bool {
        sourceFile != nil || !providerFiles.isEmpty || fields.contains { !$0.value.isEmpty }
    }

    @discardableResult
    func setProviderFile(_ url: URL, fieldName: String) -> Bool {
        do {
            guard let field = provider?.field(named: fieldName), field.kind == .secretFile,
                  let format = field.fileFormat else { throw ClipboardSaveError.wrongFieldType }
            let source = try CredentialFileSource(filePath: url.path, format: format)
            providerFileSources[fieldName] = source
            providerFiles[fieldName] = url
            errorMessage = nil
            return true
        } catch {
            errorMessage = L("Could not select this credential file. Choose an owned regular JSON or .p8 file, at most 64 KiB.")
            return false
        }
    }

    func removeProviderFile(_ fieldName: String) {
        providerFileSources[fieldName] = nil
        providerFiles[fieldName] = nil
    }

    var providerProblem: String? {
        guard let providerID else { return nil }
        guard let template = ProviderCatalog.find(providerID), template.contractProblems.isEmpty else {
            return L("The selected template is unavailable. Choose another provider.")
        }
        if template.fields.contains(where: { $0.kind == .localIdentity }) {
            return L("This is a signing identity in the macOS Keychain, not an API key. Manage it with Apple; do not paste or export its private key here.")
        }
        guard fields.map(\.name) == template.fields.map(\.name), sourceFile == nil else {
            return L("Fields no longer match this template. Select the template again.")
        }
        for (entry, field) in zip(fields, template.fields) {
            guard entry.isSecret == field.isSaveableSecret, entry.fileFormat == field.fileFormat else {
                return L("Fields no longer match this template. Select the template again.")
            }
            if field.kind == .secretFile {
                guard entry.value.isEmpty else { return L("Choose a file; do not paste file contents into a text field.") }
                if field.required && providerFileSources[field.name] == nil {
                    return L("Choose the required file: \(field.label)")
                }
                continue
            }
            if field.required && entry.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return L("Complete the required field: \(field.label)")
            }
            if !entry.value.isEmpty,
               let problem = template.shapeProblem(for: entry.value, fieldName: field.name) { return AppL10n.text(problem) }
        }
        return nil
    }

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
            if let providerProblem { errorMessage = providerProblem; return false }
            // The Save button is the user's approval to read the files shown in this form.
            // Validate every file before any Keychain write; no file contents enter UI state.
            var inputs = fields
            for i in inputs.indices {
                if let source = providerFileSources[inputs[i].name] {
                    guard let value = try source.readText() else { throw ClipboardSaveError.invalidFile }
                    inputs[i].value = value
                }
            }
            let named = inputs.filter {
                !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && (providerID == nil || !$0.value.isEmpty)
            }
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
            if let failure = plan.validationFailures.first {
                errorMessage = L("\(failure.fieldName): \(failure.reason)")
                return false
            }
            for (entry, machine) in zip(named, machineNames) {
                let typed = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if typed != machine { plan.metadata.fields[machine]?.displayName = typed }
                if let field = provider?.field(named: machine) {
                    plan.metadata.fields[machine]?.aliases = field.aliases
                    plan.metadata.fields[machine]?.displayName = field.label
                    plan.metadata.fields[machine]?.fileFormat = field.fileFormat
                }
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
                created: now, updated: now, expires: expires, injectOnly: injectOnly, provider: providerID
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
