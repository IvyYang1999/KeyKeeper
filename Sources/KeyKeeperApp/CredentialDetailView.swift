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
    @State private var copiedPrompt = false
    @Environment(\.panelLayout) private var layout

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
                    if layout == .popover {
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
                } else if layout == .embedded {
                    HStack(alignment: .center, spacing: 14) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 46, height: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vm.credential.label).font(.system(size: 23, weight: .bold))
                            HStack(spacing: 6) {
                                Text(L("ID \(credentialId)")).font(.callout.monospaced()).textSelection(.enabled)
                                Text("·")
                                Text(SecurityLevelPresentation.badge(vm.credential.security))
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                        }
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

                // What you stored comes first, then what your agent gets.
                if vm.isEditing {
                    KeyFieldsEditor(
                        fields: $vm.fields,
                        revealStoredValue: { entry in try vm.storedValue(for: entry) },
                        onRevealError: { vm.reportRevealFailure($0) }
                    )
                    DescriptionEditor(text: $vm.credential.notes)
                } else {
                    keysCard
                    agentHandoff
                }

                // Who is approved (view mode): terminal sessions and background callers in one list
                if !vm.isEditing {
                    AccessSection(credentialId: credentialId, security: vm.credential.security)
                        .padding(layout == .embedded ? 14 : 0)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .modifier(EmbeddedCard(layout: layout))
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
                        Text(L("Created \(RecentCredentials.dayLabel(for: vm.credential.created))"))
                        Spacer()
                        Text(L("Updated \(RecentCredentials.dayLabel(for: vm.credential.updated))"))
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
        .panelFrame()
    }

    /// Field names with masked values; the eye reveals, the copy button clears itself.
    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: L("Keys"))

            ForEach(Array(vm.fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { GlassSeparator() }
                if field.fileFormat != nil {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(L("\(field.name) · Service-account JSON"), systemImage: "doc.badge.gearshape")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(L("Contents hidden. Used through a private temporary file; the downloaded original is not managed or deleted."))
                            .font(.caption2).foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    fieldRow(index: index, field: field)
                }
            }

            if copiedFieldIndex != nil {
                Text(L("Copied. The clipboard clears itself in \(Int(SecretPasteboard.clearDelay)) s unless you copy something else."))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(layout == .embedded ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EmbeddedCard(layout: layout))
    }

    private func fieldRow(index: Int, field: FieldEntry) -> some View {
        HStack(spacing: 8) {
            Text(field.name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: layout == .embedded ? 190 : 110, alignment: .leading)
                .help(field.name)

            Text(field.visible && !field.value.isEmpty ? field.value : "••••••••••")
                .font(.callout.monospaced())
                .foregroundColor(field.visible ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { vm.toggleFieldVisibility(at: index) }) {
                Image(systemName: field.visible ? "eye.fill" : "eye.slash.fill")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(field.visible ? L("Hide") : L("Show"))

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

    /// The one thing most people do with a stored key: tell their agent to use it. The note
    /// (the "visible to AI" description) travels inside the prompt, so it lives here too.
    private var agentHandoff: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: L("Hand it to your agent"), hint: L("names only, never the value"))

            Text(AgentPromptCopy.prompt(credentialId: credentialId, credential: vm.credential, includeNote: false))
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(layout == .embedded ? 5 : 3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Note for your agent"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    Text(L("added to the end of the prompt"))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                if vm.credential.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(L("No note yet. Add what it is for, its limits or which environment to use; it goes into the prompt."))
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(L("Add a note\u{2026}")) { vm.isEditing = true }
                        .buttonStyle(.plain)
                        .font(.callout)
                        .foregroundColor(.accentColor)
                } else {
                    Text(vm.credential.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.inset, radius: DS.Radius.sm)

            Button {
                PlainPasteboard.copy(AgentPromptCopy.prompt(credentialId: credentialId, credential: vm.credential))
                copiedPrompt = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedPrompt = false }
            } label: {
                Label(copiedPrompt ? L("Copied") : L("Copy prompt for your agent"),
                      systemImage: copiedPrompt ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(layout == .embedded ? .large : .regular)

            // The agent types this, not you; it stays folded for the rare manual run.
            DisclosureGroup(L("Run it yourself in a terminal")) {
                VStack(alignment: .leading, spacing: 4) {
                    CopyableCommand(CredentialUsageCopy.runCommand(credentialId: credentialId, credential: vm.credential)
                        .replacingOccurrences(of: "<your command>", with: L("<your command>")))
                    let names = CredentialUsageCopy.environmentNames(for: vm.credential)
                    if !names.isEmpty {
                        Text(L("Environment variables: \(names.joined(separator: "  "))"))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(layout == .embedded ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(EmbeddedCard(layout: layout))
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

/// In the main window the detail sections sit on cards; in the popover they stay flat.
private struct EmbeddedCard: ViewModifier {
    let layout: PanelLayout
    func body(content: Content) -> some View {
        if layout == .embedded {
            content.surface(.card)
        } else {
            content
        }
    }
}
