import SwiftUI
import KeyKeeperCore

struct CredentialDetailView: View {
    let credentialId: String
    @State private var credential: Credential
    @State private var fields: [FieldEntry] = []
    @State private var security: SecurityLevel
    @State private var isEditing = false
    @State private var errorMessage: String?
    @State private var originalLabel: String
    var onBack: () -> Void
    var onUpdate: () -> Void

    private let keychain = KeychainService()
    private let store = MetaStore.default

    init(credentialId: String, credential: Credential, onBack: @escaping () -> Void, onUpdate: @escaping () -> Void) {
        self.credentialId = credentialId
        self._credential = State(initialValue: credential)
        self._security = State(initialValue: credential.security)
        self._originalLabel = State(initialValue: credential.label)
        self.onBack = onBack
        self.onUpdate = onUpdate

        // Build field entries from credential (values loaded later from Keychain)
        let entries = credential.fields.sorted { $0.key < $1.key }.map { name, field in
            FieldEntry(name: name, value: "", visible: false, existingSecret: field.secret)
        }
        self._fields = State(initialValue: entries)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Button(action: onBack) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    Spacer()
                    Button(isEditing ? "Cancel" : "Edit") {
                        if isEditing {
                            // Revert changes
                            reloadCredential()
                        }
                        isEditing.toggle()
                    }
                    .font(.caption)
                }

                // Name
                if isEditing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Name").font(.subheadline.bold())
                        TextField("Name", text: $credential.label)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    Text(credential.label).font(.headline)
                }

                // Description
                if isEditing {
                    DescriptionEditor(text: $credential.notes)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Description").font(.subheadline.bold())
                            Text("visible to AI").font(.caption).foregroundColor(.secondary)
                        }
                        if credential.notes.isEmpty {
                            Text("No description")
                                .font(.callout).foregroundColor(.secondary)
                        } else {
                            Text(credential.notes)
                                .font(.callout).foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Keys
                if isEditing {
                    KeyFieldsEditor(fields: $fields)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keys").font(.subheadline.bold())

                        ForEach(fields.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                Text(fields[i].name)
                                    .font(.callout.monospaced())
                                    .frame(width: 100, alignment: .leading)

                                MaskedValueField(
                                    value: $fields[i].value,
                                    visible: $fields[i].visible,
                                    placeholder: "••••••••",
                                    editable: false,
                                    onCopy: { copyFieldValue(fields[i].name) }
                                )
                            }
                        }
                    }
                }

                // Grants (view mode, strict only)
                if !isEditing && credential.security == .strict {
                    GrantsSection(credentialId: credentialId)
                }

                // Advanced (edit mode only)
                if isEditing {
                    AdvancedSecuritySection(security: $security)
                }

                // Error
                if let error = errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                // Save button (edit mode)
                if isEditing {
                    HStack {
                        Spacer()
                        Button("Save") {
                            saveChanges()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // Metadata
                if !isEditing {
                    HStack {
                        Text("Created \(credential.created)")
                        Spacer()
                        Text("Updated \(credential.updated)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.5))
                }
            }
            .padding()
        }
        .frame(width: 380, height: 480)
        .onAppear { loadFieldValues() }
    }

    private func loadFieldValues() {
        for i in fields.indices {
            if fields[i].existingSecret {
                do {
                    fields[i].value = try keychain.retrieve(
                        credentialId: credentialId, fieldName: fields[i].name
                    )
                } catch {
                    fields[i].value = ""
                }
            }
        }
    }

    private func reloadCredential() {
        do {
            let meta = try store.load()
            if let cred = meta.credentials[credentialId] {
                credential = cred
                security = cred.security
                fields = cred.fields.sorted { $0.key < $1.key }.map { name, field in
                    FieldEntry(name: name, value: "", visible: false, existingSecret: field.secret)
                }
                loadFieldValues()
            }
        } catch {}
    }

    private func copyFieldValue(_ fieldName: String) {
        do {
            let value = try keychain.retrieve(credentialId: credentialId, fieldName: fieldName)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        } catch {
            errorMessage = "Copy failed: \(error.localizedDescription)"
        }
    }

    private func saveChanges() {
        do {
            var meta = try store.load()

            // Save key values to Keychain
            for field in fields where !field.name.isEmpty && !field.value.isEmpty {
                try keychain.save(
                    credentialId: credentialId, fieldName: field.name,
                    value: field.value, security: security
                )
            }

            // Build credential fields
            var credFields: [String: CredentialField] = [:]
            for field in fields where !field.name.isEmpty {
                credFields[field.name] = CredentialField(secret: true)
            }

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"

            // Only update timestamp if something actually changed
            let hasChanges = credential.label != originalLabel
                || credential.notes != meta.credentials[credentialId]?.notes
                || credFields.keys.sorted() != meta.credentials[credentialId]?.fields.keys.sorted()
                || security != meta.credentials[credentialId]?.security

            credential.fields = credFields
            credential.security = security
            if hasChanges {
                credential.updated = formatter.string(from: Date())
            }

            meta.credentials[credentialId] = credential
            try store.save(meta)
            onUpdate()
            isEditing = false
            errorMessage = nil
            originalLabel = credential.label
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
        }
    }
}
