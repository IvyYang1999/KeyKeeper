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
    @State private var showDiscardConfirmation = false
    @State private var copiedFieldIndex: Int?

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
                    Button(action: {
                        if vm.isEditing {
                            showDiscardConfirmation = true
                        } else {
                            onBack()
                        }
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text(L("Back"))
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                    .confirmationDialog(
                        L("Discard unsaved changes?"),
                        isPresented: $showDiscardConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("Discard Changes"), role: .destructive) {
                            vm.reloadCredential()
                            vm.isEditing = false
                            onBack()
                        }
                        Button(L("Keep Editing"), role: .cancel) {}
                    }
                    Spacer()
                    Button(vm.isEditing ? L("Cancel") : L("Edit")) {
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
                        SectionLabel(text: L("Name"))
                        TextField(L("Name"), text: $vm.credential.label)
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
                        Text(L("ID \(credentialId)"))
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
                        SectionLabel(text: L("Description"), hint: L("visible to AI"))
                        if vm.credential.notes.isEmpty {
                            Text(L("No description"))
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
                    KeyFieldsEditor(
                        fields: $vm.fields,
                        revealStoredValue: { entry in try vm.storedValue(for: entry) },
                        onRevealError: { vm.reportRevealFailure($0) }
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: L("Keys"))

                        ForEach(Array(vm.fields.enumerated()), id: \.offset) { index, field in
                            if field.fileFormat != nil {
                                Label(L("\(field.name) · Service-account JSON"), systemImage: "doc.badge.gearshape")
                                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                                Text(L("Contents hidden. Used through a private temporary file; the downloaded original is not managed or deleted."))
                                    .font(.caption2).foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
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
                                        let changeCount = SecretPasteboard.write(value)
                                        SecretPasteboard.scheduleClear(after: changeCount)
                                        copiedFieldIndex = index
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                            if copiedFieldIndex == index { copiedFieldIndex = nil }
                                        }
                                    }
                                }) {
                                    Image(systemName: copiedFieldIndex == index ? "checkmark" : "doc.on.doc")
                                        .foregroundColor(copiedFieldIndex == index ? .green : .secondary)
                                        .frame(width: 18)
                                }
                                .buttonStyle(.plain)
                                .help(L("Copy value (clipboard is cleared after \(Int(SecretPasteboard.clearDelay)) s)"))
                            }
                            }
                        }

                        if copiedFieldIndex != nil {
                            Text(L("Copied. The clipboard clears itself in \(Int(SecretPasteboard.clearDelay)) s unless you copy something else."))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // How to use it (view mode)
                if !vm.isEditing {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        SectionLabel(text: L("Use in terminal"), hint: L("text values or private file paths"))
                        CopyableCommand(CredentialUsageCopy.runCommand(credentialId: credentialId, credential: vm.credential))
                        let names = CredentialUsageCopy.environmentNames(for: vm.credential)
                        if !names.isEmpty {
                            Text(names.joined(separator: "  "))
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                // Who is approved (view mode): terminal sessions and background callers in one list
                if !vm.isEditing {
                    AccessSection(credentialId: credentialId, security: vm.credential.security)
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
                        Button(L("Save")) {
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
                        Text(L("Created \(vm.credential.created)"))
                        Spacer()
                        Text(L("Updated \(vm.credential.updated)"))
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.4))

                    Divider()

                    Button {
                        showDeleteConfirmation = true
                    } label: {
                        Label(L("Delete this credential\u{2026}"), systemImage: "trash")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        L("Delete \"\(vm.credential.label)\"?"),
                        isPresented: $showDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button(L("Delete"), role: .destructive) {
                            if let problem = onDelete() {
                                vm.errorMessage = problem
                            }
                        }
                        Button(L("Cancel"), role: .cancel) {}
                    } message: {
                        Text(CredentialDeletionCopy.message(credentialId: credentialId))
                    }
                }
            }
            .padding()
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
    }

}

enum CredentialUsageCopy {
    static func runCommand(credentialId: String, credential: Credential? = nil) -> String {
        let files = credential?.fields.filter { $0.value.fileFormat != nil }.keys.sorted() ?? []
        let mappings = files.enumerated().map { index, field in
            let variable = files.count == 1 ? "GOOGLE_APPLICATION_CREDENTIALS" : "CREDENTIAL_FILE_\(index + 1)"
            return " --file \(credentialId):\(field)=\(variable)"
        }.joined()
        return "keykeeper run -c \(credentialId)\(mappings) -- <your command>"
    }

    static func environmentNames(for credential: Credential) -> [String] {
        credential.fields
            .filter { $0.value.secret && $0.value.fileFormat == nil }
            .keys
            .sorted()
            .map { EnvironmentVariableName.from(fieldName: $0) }
    }
}
