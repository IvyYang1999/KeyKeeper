import Foundation
import KeyKeeperCore

@MainActor
final class CredentialDetailViewModel: ObservableObject {
    let credentialId: String
    @Published var credential: Credential
    @Published var fields: [FieldEntry]
    @Published var security: SecurityLevel
    @Published var isEditing = false
    @Published var errorMessage: String?

    private let session: any CredentialSessionManaging
    private let store: MetaStore
    private var originalLabel: String

    init(
        credentialId: String,
        credential: Credential,
        session: any CredentialSessionManaging,
        store: MetaStore = .default
    ) {
        self.credentialId = credentialId
        self.credential = credential
        self.session = session
        self.store = store
        security = credential.security
        originalLabel = credential.label
        fields = Self.fieldEntries(for: credential)
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
            fields = Self.fieldEntries(for: storedCredential)
            errorMessage = nil
        } catch {
            errorMessage = L("Reload failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    func saveChanges() -> Bool {
        do {
            try CredentialOperationMessages.requireWritableStorage(session)
            var meta = try store.load()
            let existingFields = meta.credentials[credentialId]?.fields ?? [:]
            for (name, field) in existingFields where field.fileFormat != nil {
                let matching = fields.filter { $0.name == name }
                guard matching.count == 1, matching[0].value.isEmpty, matching[0].fileFormat == field.fileFormat else {
                    errorMessage = L("File contents cannot be changed in the text editor. Import a new credential ID instead.")
                    return false
                }
            }
            let plan = CredentialEditPlan(
                inputFields: fields.map { .init(name: $0.name, value: $0.value, originalName: $0.originalName) },
                existingFields: existingFields,
                security: security
            )

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

            credential.fields = plan.metadata.fields
            credential.security = plan.metadata.security
            if hasChanges {
                credential.updated = formatter.string(from: Date())
            }

            meta.credentials[credentialId] = credential
            try store.save(meta)
            isEditing = false
            errorMessage = nil
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
                value: "",
                visible: false,
                existingSecret: field.secret,
                fileFormat: field.fileFormat,
                originalName: name
            )
        }
    }
}
