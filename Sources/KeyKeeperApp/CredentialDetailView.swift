import SwiftUI
import KeyKeeperCore

struct CredentialDetailView: View {
    let credentialId: String
    @StateObject private var vm: CredentialDetailViewModel
    var onBack: () -> Void
    var onUpdate: () -> Void

    init(
        credentialId: String,
        credential: Credential,
        session: any CredentialSessionManaging,
        onBack: @escaping () -> Void,
        onUpdate: @escaping () -> Void
    ) {
        self.credentialId = credentialId
        _vm = StateObject(wrappedValue: CredentialDetailViewModel(
            credentialId: credentialId,
            credential: credential,
            session: session
        ))
        self.onBack = onBack
        self.onUpdate = onUpdate
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
                    Text(vm.credential.label).font(.headline)
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
                }
            }
            .padding()
        }
        .frame(width: 380, height: 480)
    }

}
