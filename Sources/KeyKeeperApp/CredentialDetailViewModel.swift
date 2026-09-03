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
        if fields[index].visible {
            fields[index].visible = false
            return
        }

        do {
            try CredentialOperationMessages.requireUnlocked(session)
            if fields[index].existingSecret, fields[index].value.isEmpty {
                fields[index].value = try session.retrieve(
                    credentialId: credentialId,
                    fieldName: fields[index].name
                )
            }
            fields[index].visible = true
            errorMessage = nil
        } catch {
            fields[index].value = ""
            fields[index].visible = false
            errorMessage = CredentialOperationMessages.failure(
                action: "reveal this secret",
                fallbackPrefix: "Failed to read key",
                error: error
            )
        }
    }

    func copyFieldValue(_ fieldName: String) -> String? {
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
                action: "copy this secret",
                fallbackPrefix: "Copy failed",
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
            errorMessage = "Reload failed: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func saveChanges() -> Bool {
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
                action: "save these changes",
                fallbackPrefix: "Save failed",
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
                existingSecret: field.secret
            )
        }
    }
}
