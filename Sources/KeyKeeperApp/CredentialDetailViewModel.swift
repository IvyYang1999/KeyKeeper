import Foundation
import KeyKeeperCore

@MainActor
final class CredentialDetailViewModel: ObservableObject {
    let credentialId: String
    @Published var credential: Credential
    /// Resolve a legacy spelling only for the picker; opening a detail must not migrate storage.
    var providerSelection: String {
        credential.provider.flatMap(ProviderCatalog.find)?.id ?? credential.provider ?? ""
    }
    @Published var fields: [FieldEntry]
    @Published var security: SecurityLevel
    @Published var injectOnly: Bool
    @Published var isEditing = false
    @Published var errorMessage: String?
    /// Problems that belong to one key row, keyed by `FieldEntry.id`, shown under that row.
    @Published var fieldErrors: [UUID: String] = [:]
    /// The group ID being edited. Saving a different one renames the credential; the old
    /// ID keeps working as an alias.
    @Published var groupIdDraft: String
    /// Set after a save renamed the credential, so the window can follow it to the new ID.
    @Published private(set) var renamedGroupId: String?

    private let session: any CredentialSessionManaging
    private let store: MetaStore
    private let approvals: ApprovalStore
    private var originalLabel: String

    init(
        credentialId: String,
        credential: Credential,
        session: any CredentialSessionManaging,
        store: MetaStore = .default,
        approvals: ApprovalStore
    ) {
        self.credentialId = credentialId
        self.credential = credential
        self.session = session
        self.store = store
        self.approvals = approvals
        security = credential.security
        injectOnly = credential.isInjectOnly
        originalLabel = credential.label
        fields = Self.fieldEntries(for: credential)
        groupIdDraft = credentialId
    }

    func toggleFieldVisibility(at index: Int) {
        guard fields.indices.contains(index) else { return }
        guard fields[index].fileFormat == nil else { return }
        if fields[index].visible {
            fields[index].visible = false
            return
        }

        do {
            try store.withAccess {
                try CredentialOperationMessages.requireUnlocked(session)
                _ = try store.loadForUse()
                try KeyFieldsEditor.toggleVisibility(of: &fields, at: index) { entry in
                    try self.session.retrieve(credentialId: self.credentialId, fieldName: entry.originalName ?? entry.name)
                }
                errorMessage = nil
            }
        } catch {
            fields[index].value = ""
            fields[index].visible = false
            errorMessage = CredentialOperationMessages.failure(
                action: L("reveal this secret"),
                fallbackPrefix: L("Failed to read key"),
                error: error
            )
        }
    }

    /// Opens the editor on what is stored now, with a masked look at each saved secret.
    func beginEditing() {
        fieldErrors = [:]
        errorMessage = nil
        isEditing = true
        loadStoredPreviews()
    }

    /// Leaves the editor without saving anything typed.
    func cancelEditing() {
        reloadCredential()
        fieldErrors = [:]
        isEditing = false
    }

    /// 【曾经的 bug】2026-11-07 yyt：编辑页里已存的值只写「未修改」，连 sk***Kk 这样的简略样子都没有，
    /// 分不清哪把是哪把。Reads each stored secret of this one credential once and keeps only
    /// its mask: the row's value stays empty, so an untouched row is still "unchanged" on save.
    /// A secret whose value is gone is marked, which is also how a missing value gets typed back.
    func loadStoredPreviews() {
        let stored = try? session.storedFieldNames(credentialId: credentialId)
        for index in fields.indices where fields[index].existingSecret && fields[index].fileFormat == nil
            && fields[index].value.isEmpty {
            let name = fields[index].originalName ?? fields[index].name
            if let stored, !stored.contains(name) {
                fields[index].storedMissing = true
                continue
            }
            if let value = try? storedValue(for: fields[index]) {
                fields[index].storedPreview = MaskedFieldPresentation.mask(value)
            }
        }
    }

    /// Every row gets a field name before anything is checked or written. The person writes
    /// one name; a row without a field name takes it from that wording, and one that cannot
    /// be used by scripts as typed ("Access Token") becomes the safe form shown under it, the
    /// wording kept as its display name. Rows that are still wrong are reported where they are.
    ///
    /// 【曾经的 bug】2026-11-07 yyt：名字填在显示名里、名称留空，保存后新字段连值一起消失；
    /// 名称带空格又被拒绝，明明底下已经生成了能用的写法。
    static func prepareRows(_ rows: [FieldEntry]) -> (rows: [FieldEntry], problems: [UUID: String]) {
        var prepared: [FieldEntry] = []
        var problems: [UUID: String] = [:]
        var seen: [String: String] = [:]
        for var row in rows {
            let name = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let wording = row.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            row.displayName = wording
            if name.isEmpty {
                if !wording.isEmpty {
                    row.name = AddCredentialViewModel.machineFieldName(wording)
                } else if row.value.isEmpty, row.originalName == nil, row.fileFormat == nil {
                    continue   // a blank row the person never filled in
                } else {
                    row.name = ""
                    problems[row.id] = L("Give this key a name.")
                    prepared.append(row)
                    continue
                }
            } else if name != row.originalName, !CredentialNames.isValidFieldName(name) {
                if wording.isEmpty { row.displayName = name }
                row.name = AddCredentialViewModel.machineFieldName(name)
            } else {
                row.name = name
            }
            if row.displayName == row.name { row.displayName = "" }
            if row.name != row.originalName, EnvironmentVariableName.isReserved(fieldName: row.name) {
                problems[row.id] = MetadataEditCopy.message(.reservedFieldName(row.name))
            } else if let first = seen[row.name] {
                problems[row.id] = L("Same name as \u{201C}\(first)\u{201D} above. Use another name.")
            }
            if seen[row.name] == nil { seen[row.name] = row.title }
            prepared.append(row)
        }
        return (prepared, problems)
    }

    /// Stored value for an editor row; used by the edit-mode eye.
    func storedValue(for entry: FieldEntry) throws -> String {
        return try store.withAccess {
            try CredentialOperationMessages.requireUnlocked(session)
            _ = try store.loadForUse()
            return try self.session.retrieve(credentialId: self.credentialId, fieldName: entry.originalName ?? entry.name)
        }
    }

    func reportRevealFailure(_ error: Error) {
        errorMessage = CredentialOperationMessages.failure(
            action: L("reveal this secret"),
            fallbackPrefix: L("Failed to read key"),
            error: error
        )
    }

    /// Moving a stored secret into plain text needs its value in hand first — the plan refuses
    /// to delete a Keychain entry it has nothing to replace. Returns false when the read failed.
    @discardableResult
    func loadValueForPlainConversion(at index: Int) -> Bool {
        guard fields.indices.contains(index) else { return false }
        guard fields[index].existingSecret, fields[index].value.isEmpty else { return true }
        do {
            fields[index].value = try storedValue(for: fields[index])
            fields[index].visible = true
            errorMessage = nil
            return true
        } catch {
            reportRevealFailure(error)
            return false
        }
    }

    /// Reads a service-account file once and keeps only its client_email and project_id for
    /// display. The document itself is dropped right away and never reaches `fields`.
    func serviceAccountSummary(fieldName: String) -> ServiceAccountSummary? {
        try? store.withAccess {
            guard credential.fields[fieldName]?.fileFormat == .serviceAccountJSON else { return nil }
            try CredentialOperationMessages.requireUnlocked(session)
            _ = try store.loadForUse()
            let document = try session.retrieve(credentialId: credentialId, fieldName: fieldName)
            return ServiceAccountSummary.parse(document)
        }
    }

    func copyFieldValue(_ fieldName: String) -> String? {
        guard credential.fields[fieldName]?.fileFormat == nil else { return nil }
        do {
            return try store.withAccess {
                try CredentialOperationMessages.requireUnlocked(session)
                _ = try store.loadForUse()
                let value = try session.retrieve(
                    credentialId: credentialId,
                    fieldName: fieldName
                )
                errorMessage = nil
                return value
            }
        } catch {
            errorMessage = CredentialOperationMessages.failure(
                action: L("copy this secret"),
                fallbackPrefix: L("Copy failed"),
                error: error
            )
            return nil
        }
    }

    func reloadCredential() {
        do {
            let meta = try store.loadForUse()
            guard let storedCredential = meta.credentials[credentialId] else { return }
            credential = storedCredential
            security = storedCredential.security
            injectOnly = storedCredential.isInjectOnly
            fields = Self.fieldEntries(for: storedCredential)
            groupIdDraft = credentialId
            errorMessage = nil
            fieldErrors = [:]
        } catch {
            errorMessage = L("Reload failed: \(error.localizedDescription)")
        }
    }

    /// Bind to a provider template (or nil to unbind): what the key looks like, how it is
    /// verified, what an agent is told. A hint, like notes: saved at once, no prompt.
    func setProvider(_ providerId: String?) {
        do {
            try store.withAccess {
                var meta = try store.prepareForMutation()
                guard meta.credentials[credentialId] != nil else { return }
                meta.credentials[credentialId]?.provider = providerId
                try store.save(meta)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                reloadCredential()
            }
        } catch {
            errorMessage = L("Could not change: \(error.localizedDescription)")
        }
    }

    /// Whether `get` and the SDKs may read values out, or only `run` may inject them. Saved at once.
    func setInjectOnly(_ value: Bool) {
        do {
            try store.withAccess {
                var meta = try store.prepareForMutation()
                guard meta.credentials[credentialId] != nil else { return }
                meta.credentials[credentialId]?.injectOnly = value
                try store.save(meta)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                reloadCredential()
            }
        } catch {
            errorMessage = L("Could not change: \(error.localizedDescription)")
        }
    }

    /// The person has looked at a plain value a caller wrote: from now on `run` injects it.
    func confirmPlainField(_ name: String) {
        do {
            try store.withAccess {
                var meta = try store.prepareForMutation()
                guard meta.credentials[credentialId]?.fields[name]?.setByCaller != nil else { return }
                meta.credentials[credentialId]?.fields[name]?.setByCaller = nil
                try store.save(meta)
                NotificationCenter.default.post(name: .credentialsChanged, object: nil)
                reloadCredential()
            }
        } catch {
            errorMessage = L("Could not confirm: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveChanges() -> Bool {
        do {
            return try store.withAccess {
                try CredentialOperationMessages.requireUnlocked(session)
                var meta = try store.prepareForMutation()
                let existingFields = meta.credentials[credentialId]?.fields ?? [:]
                for (name, field) in existingFields where field.fileFormat != nil {
                    let matching = fields.filter { $0.name == name }
                    guard matching.count == 1, matching[0].value.isEmpty, matching[0].fileFormat == field.fileFormat else {
                        errorMessage = L("File contents cannot be changed in the text editor. Import a new credential ID instead.")
                        return false
                    }
                }
                // Name every row first, so a value is never dropped for want of a field name.
                let prepared = Self.prepareRows(fields)
                fields = prepared.rows
                fieldErrors = prepared.problems
                if !fieldErrors.isEmpty {
                    errorMessage = L("Some keys need a fix before saving; see the marked rows.")
                    return false
                }
                // Check names before touching anything, so a bad one never leaves a half-saved edit.
                let newGroupId = groupIdDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if newGroupId != credentialId {
                    _ = try MetadataEditPlan.apply(MetadataEdit(newGroupId: newGroupId), to: meta, groupId: credentialId)
                }
                for entry in fields where !entry.name.isEmpty && entry.name != entry.originalName {
                    guard CredentialNames.isValidFieldName(entry.name) else {
                        errorMessage = L("Field names can only use letters, digits, '-', '_' and '.', with no spaces. Put the wording you like in the display name.")
                        return false
                    }
                    guard !EnvironmentVariableName.isReserved(fieldName: entry.name) else {
                        errorMessage = MetadataEditCopy.message(.reservedFieldName(entry.name))
                        return false
                    }
                }
                var plan = CredentialEditPlan(
                    inputFields: fields.map { .init(name: $0.name, value: $0.value, originalName: $0.originalName, isSecret: $0.isSecret) },
                    existingFields: existingFields,
                    security: security
                )
                if let failure = plan.validationFailures.first {
                    if let row = fields.first(where: { $0.name == failure.fieldName }) {
                        fieldErrors[row.id] = failure.reason
                    }
                    errorMessage = L("\(failure.fieldName): \(failure.reason)")
                    return false
                }
                var displayNamesChanged = false
                for entry in fields where !entry.name.isEmpty {
                    let trimmed = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = trimmed.isEmpty ? nil : trimmed
                    if plan.metadata.fields[entry.name] != nil, plan.metadata.fields[entry.name]?.displayName != value {
                        plan.metadata.fields[entry.name]?.displayName = value
                        displayNamesChanged = true
                    }
                }

                // Completeness is judged for this credential only: a store where *other* credentials
                // lost their values must not block editing a healthy one. Within this credential the
                // old protection stands — metadata is the last record of what went missing — except
                // for the edit that fixes it: typing the value back in.
                do {
                    // Fail closed: if the store can't even be read (the whole Keychain item is gone),
                    // nothing may be written — that is the recovery case this protection exists for.
                    let stored = try session.storedFieldNames(credentialId: credentialId)
                    let missing = Set(existingFields.filter { $0.value.secret }.keys).subtracting(stored)
                    let supplied = Set(plan.valueWrites.map(\.fieldName))
                    let unresolved = missing.filter { !supplied.contains($0) && !supplied.contains(plan.fieldRenames[$0] ?? $0) }
                    if !unresolved.isEmpty {
                        errorMessage = L("\u{201C}\(unresolved.sorted().joined(separator: ", "))\u{201D} has no stored value. Type the value back in to save this credential; other changes stay blocked until then, so the record of what went missing is kept.")
                        return false
                    }
                } catch let error as ClipboardSaveError where error == .storageUnavailable {
                    // A session that cannot enumerate its store (test doubles, legacy providers):
                    // fall back to the whole-store check rather than skipping verification.
                    try CredentialOperationMessages.requireWritableStorage(session)
                }

                // Renames first: the old value must be copied before deletions remove it.
                for rename in plan.valueRenames {
                    let value = try session.retrieve(credentialId: credentialId, fieldName: rename.from)
                    try session.save(
                        credentialId: credentialId,
                        fieldName: rename.to,
                        value: value,
                        security: plan.metadata.security
                    )
                }
                for fieldName in plan.valueDeletions {
                    try session.delete(credentialId: credentialId, fieldName: fieldName)
                }
                for write in plan.valueWrites {
                    try session.save(
                        credentialId: credentialId,
                        fieldName: write.fieldName,
                        value: write.value,
                        security: plan.metadata.security
                    )
                }

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                let hasChanges = credential.label != originalLabel
                    || credential.notes != meta.credentials[credentialId]?.notes
                    || plan.metadata.fields.keys.sorted()
                        != meta.credentials[credentialId]?.fields.keys.sorted()
                    || security != meta.credentials[credentialId]?.security
                    || !plan.valueWrites.isEmpty
                    || !plan.valueRenames.isEmpty
                    || displayNamesChanged
                    || credential.expires != meta.credentials[credentialId]?.expires

                credential.fields = plan.metadata.fields
                credential.security = plan.metadata.security
                if hasChanges {
                    credential.updated = formatter.string(from: Date())
                }

                meta.credentials[credentialId] = credential
                try store.save(meta)

                // Only now that metadata holds the plain value is it safe to drop the old secret.
                // A failure here is not worth losing the save over — metadata is already written —
                // but it must not be silent either: the confirmation just told the user the value
                // left the Keychain, and it did not.
                var strandedFields: [String] = []
                for fieldName in plan.keychainDropsAfterCommit {
                    do {
                        try session.delete(credentialId: credentialId, fieldName: fieldName)
                    } catch {
                        strandedFields.append(fieldName)
                    }
                }

                if !plan.fieldRenames.isEmpty {
                    // Approvals name fields; without this a rename silently voided them.
                    try? approvals.moveCredential(from: credentialId, to: credentialId, fieldMap: plan.fieldRenames)
                }
                if newGroupId != credentialId {
                    let editor = MetadataEditor(session: session, metaStore: store, approvals: approvals)
                    let result = try editor.apply(MetadataEdit(newGroupId: newGroupId), groupId: credentialId)
                    renamedGroupId = result.groupId
                }
                isEditing = false
                // Back to what is stored: no typed value stays in memory after the editor closes.
                fields = Self.fieldEntries(for: credential)
                errorMessage = strandedFields.isEmpty ? nil : L(
                    "Saved, but the old Keychain copy of \(strandedFields.sorted().joined(separator: ", ")) could not be removed. That value is now stored in two places."
                )
                originalLabel = credential.label
                return true
            }
        } catch {
            errorMessage = CredentialOperationMessages.failure(
                action: L("save these changes"),
                fallbackPrefix: L("Save failed"),
                error: error
            )
            return false
        }
    }

    private static func fieldEntries(for credential: Credential) -> [FieldEntry] {
        credential.fields.sorted { $0.key < $1.key }.map { name, field in
            FieldEntry(
                name: name,
                // A plain value has nothing to hide: show it as it is, ready to edit.
                value: field.secret ? "" : (field.value ?? ""),
                visible: !field.secret,
                existingSecret: field.secret,
                fileFormat: field.fileFormat,
                originalName: name,
                displayName: field.displayName ?? "",
                setByCaller: field.setByCaller,
                isSecret: field.secret
            )
        }
    }
}
