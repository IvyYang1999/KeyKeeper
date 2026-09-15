import SwiftUI
import KeyKeeperCore

struct CredentialDetailView: View {
    let credentialId: String
    var valueAvailability: CredentialValueAvailability
    var onCheckValues: () -> Void
    @StateObject private var vm: CredentialDetailViewModel
    var onBack: () -> Void
    var onUpdate: () -> Void
    /// Deletes the credential. Returns an error message, or nil when it succeeded.
    var onDelete: () -> String?
    /// Called with the new group ID after a save renamed the credential.
    var onRenamed: (String) -> Void = { _ in }

    @State private var showDeleteConfirmation = false
    @State private var showDiscardConfirmation = false
    @State private var copiedFieldIndex: Int?
    @State private var copiedPrompt = false
    @State private var summaries: [String: ServiceAccountSummary] = [:]
    /// Index of the field the person is moving out of the Keychain into plain text.
    @State private var pendingPlainConversion: Int?
    @Environment(\.panelLayout) private var layout

    init(
        credentialId: String,
        credential: Credential,
        session: any CredentialSessionManaging,
        valueAvailability: CredentialValueAvailability = .init(state: .unchecked),
        onCheckValues: @escaping () -> Void = {},
        onBack: @escaping () -> Void,
        onUpdate: @escaping () -> Void,
        onDelete: @escaping () -> String?,
        onRenamed: @escaping (String) -> Void = { _ in }
    ) {
        self.credentialId = credentialId
        self.valueAvailability = valueAvailability
        self.onCheckValues = onCheckValues
        _vm = StateObject(wrappedValue: CredentialDetailViewModel(
            credentialId: credentialId,
            credential: credential,
            session: session,
            approvals: .shared
        ))
        self.onBack = onBack
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.onRenamed = onRenamed
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
                        SectionLabel(text: L("Group ID"), hint: L("what keykeeper run -c uses; old IDs keep working"))
                            .padding(.top, 6)
                        TextField(L("Group ID"), text: $vm.groupIdDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout.monospaced())
                    }
                } else if layout == .embedded {
                    HStack(alignment: .center, spacing: 14) {
                        KeyAvatar(credential: vm.credential, size: 46)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vm.credential.label).font(.system(size: 23, weight: .bold))
                            HStack(spacing: 6) {
                                Text(L("Group ID \(credentialId)")).font(.callout.monospaced()).textSelection(.enabled)
                                    .help(L("The name scripts and agents pass to keykeeper run -c. It is not a key name."))
                                CopyTextButton(text: credentialId, help: L("Copy group ID"))
                                Text("·")
                                Text(SecurityLevelPresentation.badge(vm.credential.security))
                            }
                            .font(.callout)
                            .foregroundColor(.secondary)
                            if let aliases = vm.credential.aliases, !aliases.isEmpty {
                                Text(L("Also answers to \(aliases.joined(separator: ", ")) (old IDs keep working)"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            // yyt 2026-09-15: binding an existing key to a provider tells an agent how to use it.
                            HStack(spacing: 6) {
                                Text(L("Provider")).font(.caption).foregroundColor(.secondary)
                                Picker("", selection: Binding(get: { vm.credential.provider ?? "" }, set: { vm.setProvider($0.isEmpty ? nil : $0) })) {
                                    Text(L("None")).tag("")
                                    ForEach(ProviderCatalog.all) { template in
                                        Text(template.name).tag(template.id)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 180)
                                if let provider = vm.credential.provider {
                                    ProviderMark(providerId: provider, size: 16, colored: true)
                                        .help(L("The key's shape, verification and the guidance agents get come from this template."))
                                }
                            }
                            .padding(.top, 2)
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
                        Text(L("Group ID \(credentialId)"))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                }

                // What you stored comes first, then what your agent gets.
                if vm.isEditing {
                    KeyFieldsEditor(
                        fields: $vm.fields,
                        showsDisplayName: true,
                        onConvertToPlain: { pendingPlainConversion = $0 },
                        revealStoredValue: { entry in try vm.storedValue(for: entry) },
                        onRevealError: { vm.reportRevealFailure($0) }
                    )
                    .confirmationDialog(
                        L("Store this value as plain text?"),
                        isPresented: Binding(get: { pendingPlainConversion != nil },
                                             set: { if !$0 { pendingPlainConversion = nil } }),
                        titleVisibility: .visible
                    ) {
                        Button(L("Move it out of the Keychain"), role: .destructive) {
                            if let index = pendingPlainConversion, vm.loadValueForPlainConversion(at: index) {
                                vm.fields[index].isSecret = false
                            }
                            pendingPlainConversion = nil
                        }
                        Button(L("Cancel"), role: .cancel) { pendingPlainConversion = nil }
                    } message: {
                        Text(L("The value leaves the macOS Keychain and is written into KeyKeeper's metadata file in the clear, where anything running as you — your agents included — can read it. Good for an account id, an email or a region. Never for a password, token or key."))
                    }
                    DescriptionEditor(text: $vm.credential.notes)
                    ExpiryEditor(expires: $vm.credential.expires)
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
                    AdvancedSecuritySection(security: $vm.security,
                                            injectOnly: Binding(get: { vm.injectOnly }, set: { vm.setInjectOnly($0) }))
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
                                if let renamed = vm.renamedGroupId { onRenamed(renamed) }
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
            HStack {
                CredentialAvailabilityBadge(availability: valueAvailability)
                Spacer()
                Button(L("Check again"), action: onCheckValues).font(.caption)
            }

            ForEach(Array(vm.fields.enumerated()), id: \.offset) { index, field in
                if index > 0 { GlassSeparator() }
                if field.fileFormat != nil {
                    fileRows(field)
                } else {
                    fieldRow(index: index, field: field)
                        .contextMenu {
                            Button(L("Copy field name")) { PlainPasteboard.copy(field.name) }
                            Button(L("Copy environment variable name")) { PlainPasteboard.copy(EnvironmentVariableName.from(fieldName: field.name)) }
                        }
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

    /// A service-account file: marked as a file, contents hidden, plus the two non-secret
    /// facts people need — the robot's email (to grant it access) and its project.
    @ViewBuilder
    private func fileRows(_ field: FieldEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill").foregroundColor(.blue.opacity(0.8))
                Text(field.name).font(.callout.monospaced()).textSelection(.enabled)
                Text(L("Service-account JSON file")).font(.callout).foregroundColor(.secondary)
                Image(systemName: "lock.fill").font(.caption).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            Text(L("The file's contents are never shown or copied. Agents use it through keykeeper run --file, which hands the process a private temporary file."))
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let summary = summaries[field.name] {
                summaryRow("client_email", summary.clientEmail)
                if let project = summary.projectId { summaryRow("project_id", project) }
            }
        }
        .task { if summaries[field.name] == nil, let s = vm.serviceAccountSummary(fieldName: field.name) { summaries[field.name] = s } }
    }

    private func summaryRow(_ name: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.callout.monospaced())
                .frame(width: layout == .embedded ? 190 : 110, alignment: .leading)
            Text(value).font(.callout).foregroundColor(.secondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            CopyTextButton(text: value, help: L("Copy value"))
        }
    }

    private func fieldRow(index: Int, field: FieldEntry) -> some View {
        HStack(spacing: 8) {
            FieldNameLabel(field: field, credential: vm.credential)
                .frame(width: layout == .embedded ? 190 : 110, alignment: .leading)

            Text(field.isSecret
                 ? (field.visible && !field.value.isEmpty
                    ? field.value
                    : (valueAvailability.missingFields.contains(field.name) ? L("Value missing") : "••••••••••"))
                 : (field.value.isEmpty ? L("(empty)") : field.value))
                .font(.callout.monospaced())
                .foregroundColor(field.isSecret && !field.visible ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if field.isSecret {
                Button(action: { vm.toggleFieldVisibility(at: index) }) {
                    Image(systemName: field.visible ? "eye.fill" : "eye.slash.fill")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(field.visible ? L("Hide") : L("Show"))
            } else if let caller = field.setByCaller {
                // 【独立审计 2026-09-14】written over the socket by a caller, not yet seen by the
                // person: `run` leaves it out until this button is clicked (or the value is saved here).
                Button(action: { vm.confirmPlainField(field.name) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("Confirm"))
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .help(L("Written by \(TrustPromptModel.sanitizedCaller(caller)) over the command line. Not injected by `run` until you confirm it."))
            } else {
                Image(systemName: "doc.plaintext")
                    .foregroundColor(.secondary)
                    .frame(width: 18)
                    .help(L("Plain \u{00B7} readable by anything on this Mac"))
            }

            Button(action: {
                guard field.isSecret else {
                    // Plain values are not secrets: copy them straight, and don't wipe the
                    // clipboard from under someone pasting an account id somewhere else.
                    PlainPasteboard.copy(field.value)
                    copiedFieldIndex = index
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedFieldIndex == index { copiedFieldIndex = nil }
                    }
                    return
                }
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
                ProviderExpiryPolicyLine(providerId: vm.credential.provider)
                if let expiry = ExpiryPresentation.line(vm.credential.expires) {
                    Label(expiry, systemImage: "calendar")
                        .font(.callout)
                        .foregroundColor(ExpiryPresentation.badge(vm.credential.expires)?.isExpired == true ? .red : .secondary)
                }
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
                    Text(NoteText.attributed(vm.credential.notes))
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

/// Provider policy and the recorded date are different facts. This line states only the policy;
/// `ExpiryPresentation.line` below it states what was recorded for this exact credential.
struct ProviderExpiryPolicyLine: View {
    let providerId: String?

    static func text(providerId: String?) -> String? {
        guard let providerId,
              let template = ProviderCatalog.find(providerId),
              let policy = template.expiryNote else { return nil }
        return "\(template.name): \(policy)"
    }

    @ViewBuilder var body: some View {
        if let text = Self.text(providerId: providerId) {
            Label(text, systemImage: "calendar.badge.clock")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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

/// The display name people wrote, with the machine name (and earlier names) under it; or just
/// the machine name when there is no display name.
struct FieldNameLabel: View {
    let field: FieldEntry
    let credential: Credential

    var body: some View {
        let display = field.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let aliases = credential.fields[field.name]?.aliases ?? []
        VStack(alignment: .leading, spacing: 1) {
            if display.isEmpty {
                Text(field.name).font(.callout.monospaced())
            } else {
                Text(display).font(.callout)
                Text(field.name).font(.caption.monospaced()).foregroundColor(.secondary)
            }
            if !aliases.isEmpty {
                Text(L("was \(aliases.joined(separator: ", "))")).font(.caption2.monospaced()).foregroundColor(.secondary.opacity(0.8))
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .help(field.name)
    }
}
