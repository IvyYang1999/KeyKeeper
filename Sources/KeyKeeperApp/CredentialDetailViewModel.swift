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
            try CredentialOperationMessages.requireUnlocked(session)
            try KeyFieldsEditor.toggleVisibility(of: &fields, at: index) { entry in
                try self.session.retrieve(credentialId: self.credentialId, fieldName: entry.originalName ?? entry.name)
            }
            errorMessage = nil
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

    /// Stored value for an editor row; used by the edit-mode eye.
    func storedValue(for entry: FieldEntry) throws -> String {
        try CredentialOperationMessages.requireUnlocked(session)
        return try self.session.retrieve(credentialId: self.credentialId, fieldName: entry.originalName ?? entry.name)
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
        guard credential.fields[fieldName]?.fileFormat == .serviceAccountJSON,
              (try? CredentialOperationMessages.requireUnlocked(session)) != nil,
              let document = try? session.retrieve(credentialId: credentialId, fieldName: fieldName) else { return nil }
        return ServiceAccountSummary.parse(document)
    }

    func copyFieldValue(_ fieldName: String) -> String? {
        guard credential.fields[fieldName]?.fileFormat == nil else { return nil }
        do {
            try CredentialOperationMessages.requireUnlocked(session)
            let value = try session.retrieve(
                credentialId: credentialId,
                fieldName: fieldName
            )
            errorMessage = nil
            return value
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
            let meta = try store.load()
            guard let storedCredential = meta.credentials[credentialId] else { return }
            credential = storedCredential
            security = storedCredential.security
            injectOnly = storedCredential.isInjectOnly
            fields = Self.fieldEntries(for: storedCredential)
            groupIdDraft = credentialId
            errorMessage = nil
        } catch {
            errorMessage = L("Reload failed: \(error.localizedDescription)")
        }
    }

    /// Bind to a provider template (or nil to unbind): what the key looks like, how it is
    /// verified, what an agent is told. A hint, like notes: saved at once, no prompt.
    func setProvider(_ providerId: String?) {
        do {
            var meta = try store.load()
            guard meta.credentials[credentialId] != nil else { return }
            meta.credentials[credentialId]?.provider = providerId
            try store.save(meta)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            reloadCredential()
        } catch {
            errorMessage = L("Could not change: \(error.localizedDescription)")
        }
    }

    /// Whether `get` and the SDKs may read values out, or only `run` may inject them. Saved at once.
    func setInjectOnly(_ value: Bool) {
        do {
            var meta = try store.load()
            guard meta.credentials[credentialId] != nil else { return }
            meta.credentials[credentialId]?.injectOnly = value
            try store.save(meta)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            reloadCredential()
        } catch {
            errorMessage = L("Could not change: \(error.localizedDescription)")
        }
    }

    /// The person has looked at a plain value a caller wrote: from now on `run` injects it.
    func confirmPlainField(_ name: String) {
        do {
            var meta = try store.load()
            guard meta.credentials[credentialId]?.fields[name]?.setByCaller != nil else { return }
            meta.credentials[credentialId]?.fields[name]?.setByCaller = nil
            try store.save(meta)
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
            reloadCredential()
        } catch {
            errorMessage = L("Could not confirm: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveChanges() -> Bool {
        do {
            try CredentialOperationMessages.requireUnlocked(session)
            var meta = try store.load()
            let existingFields = meta.credentials[credentialId]?.fields ?? [:]
            for (name, field) in existingFields where field.fileFormat != nil {
                let matching = fields.filter { $0.name == name }
                guard matching.count == 1, matching[0].value.isEmpty, matching[0].fileFormat == field.fileFormat else {
                    errorMessage = L("File contents cannot be changed in the text editor. Import a new credential ID instead.")
                    return false
                }
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
            errorMessage = strandedFields.isEmpty ? nil : L(
                "Saved, but the old Keychain copy of \(strandedFields.sorted().joined(separator: ", ")) could not be removed. That value is now stored in two places."
            )
            originalLabel = credential.label
            return true
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
