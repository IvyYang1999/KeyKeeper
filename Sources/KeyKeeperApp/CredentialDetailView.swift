import SwiftUI
import KeyKeeperCore

struct CredentialDetailView: View {
    let credentialId: String
    @StateObject private var vm: CredentialDetailViewModel
    var onBack: () -> Void
    var onUpdate: () -> Void
    /// Deletes the credential. Returns an error message, or nil when it succeeded.
    var onDelete: () -> String?

    @State private var showDeleteConfirmation = false

    init(
        credentialId: String,
        credential: Credential,
        session: any CredentialSessionManaging,
        onBack: @escaping () -> Void,
        onUpdate: @escaping () -> Void,
        onDelete: @escaping () -> String?
    ) {
        self.credentialId = credentialId
        _vm = StateObject(wrappedValue: CredentialDetailViewModel(
            credentialId: credentialId,
            credential: credential,
            session: session
        ))
        self.onBack = onBack
        self.onUpdate = onUpdate
        self.onDelete = onDelete
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
                    Button(vm.isEditing ? "Cancel" : "Edit") {
                        if vm.isEditing {
                            vm.reloadCredential()
                        }
                        vm.isEditing.toggle()
                    }
                    .font(.caption)
                }

                // Name
                if vm.isEditing {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        SectionLabel(text: "Name")
                        TextField("Name", text: $vm.credential.label)
                            .textFieldStyle(.roundedBorder)
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        Text(vm.credential.label).font(.headline)
                        HStack(spacing: DS.Spacing.sm) {
                            SecurityBadge(level: vm.credential.security)
                            Text(SecurityLevelPresentation.title(vm.credential.security))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text("ID \(credentialId)")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // Description
                if vm.isEditing {
                    DescriptionEditor(text: $vm.credential.notes)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionLabel(text: "Description", hint: "visible to AI")
                        if vm.credential.notes.isEmpty {
                            Text("No description")
                                .font(.callout).foregroundColor(.secondary)
                        } else {
                            Text(vm.credential.notes)
                                .font(.callout).foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                // Keys
                if vm.isEditing {
                    KeyFieldsEditor(fields: $vm.fields)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Keys")

                        ForEach(Array(vm.fields.enumerated()), id: \.offset) { index, field in
                            HStack(spacing: 6) {
                                Text(field.name)
                                    .font(.callout.monospaced())
                                    .frame(width: 100, alignment: .leading)

                                Text(field.visible && !field.value.isEmpty
                                     ? field.value
                                     : "••••••••••")
                                    .font(.callout.monospaced())
                                    .foregroundColor(field.visible ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                Button(action: {
                                    vm.toggleFieldVisibility(at: index)
                                }) {
                                    Image(systemName: field.visible ? "eye.fill" : "eye.slash.fill")
                                        .foregroundColor(.secondary)
                                        .frame(width: 18)
                                }
                                .buttonStyle(.plain)

                                Button(action: {
                                    if let value = vm.copyFieldValue(field.name) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(value, forType: .string)
                                    }
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .foregroundColor(.secondary)
                                        .frame(width: 18)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // How to use it (view mode)
                if !vm.isEditing {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        SectionLabel(text: "Use in terminal", hint: "values injected as env vars")
                        CopyableCommand(CredentialUsageCopy.runCommand(credentialId: credentialId))
                        let names = CredentialUsageCopy.environmentNames(for: vm.credential)
                        if !names.isEmpty {
                            Text(names.joined(separator: "  "))
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                // Grants (view mode, strict only)
                if !vm.isEditing && vm.credential.security == .strict {
                    GrantsSection(credentialId: credentialId)
                }

                // Advanced (edit mode only)
                if vm.isEditing {
                    AdvancedSecuritySection(security: $vm.security)
                }

                // Error
                if let error = vm.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                // Save button (edit mode)
                if vm.isEditing {
                    HStack {
                        Spacer()
                        Button("Save") {
                            if vm.saveChanges() {
                                onUpdate()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                // Metadata
                if !vm.isEditing {
                    HStack {
                        Text("Created \(vm.credential.created)")
                        Spacer()
                        Text("Updated \(vm.credential.updated)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.4))

                    Divider()

                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete this credential\u{2026}", systemImage: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Delete \"\(vm.credential.label)\"?",
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            if let problem = onDelete() {
                                vm.errorMessage = problem
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(CredentialDeletionCopy.message(credentialId: credentialId))
                    }
                }
            }
            .padding()
        }
        .frame(width: 380, height: 480)
    }

}

enum CredentialUsageCopy {
    static func runCommand(credentialId: String) -> String {
        "keykeeper run -c \(credentialId) -- <your command>"
    }

    static func environmentNames(for credential: Credential) -> [String] {
        credential.fields
            .filter { $0.value.secret }
            .keys
            .sorted()
            .map { EnvironmentVariableName.from(fieldName: $0) }
    }
}
