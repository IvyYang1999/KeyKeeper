import SwiftUI
import KeyKeeperCore
import UniformTypeIdentifiers

/// The form a beginner meets first. Its happy path is two things: a name and a value.
///
/// Everything the app can decide for itself (the ID, the first key's name, the access
/// mode) is decided and shown, not asked; everything optional (description, access mode)
/// sits behind "More options". An earlier version asked for all of it at once with five
/// equally-weighted section headers and ~110 words of explanation, which pushed Save below
/// the fold on an empty form.
struct AddCredentialView: View {
    @ObservedObject var vm: AddCredentialViewModel
    var onSave: () -> Void
    var onCancel: () -> Void
    /// Called when the chosen ID is already taken and the user would rather open that one.
    var onOpenExisting: (String) -> Void
    var onImportFile: ((FileImportRequest, @escaping (ClipboardSaveResponse) -> Void) -> Void)?
    /// The open panel takes focus, which closes a non-detached popover; this brings it back.
    var afterFilePicker: () -> Void = {}

    @State private var showMoreOptions = false
    @State private var isEditingId = false
    @State private var isImporting = false
    @Environment(\.panelLayout) private var layout

    var body: some View {
        Group {
            if layout == .popover {
                if vm.providerID != nil {
                    ScrollView { form.padding(14) }
                        .frame(width: DS.Popover.width, height: 560)
                } else {
                // As tall as the form, like the other menu bar pages.
                form
                    .padding(14)
                    .frame(width: DS.Popover.width)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ScrollView { form.padding() }
                    .panelFrame()
            }
        }
        // A deep link may carry notes, and a draft may have changed the access mode — in
        // both cases the collapsed section would be hiding something that was set for the
        // user. onAppear alone missed the case where a second deep link arrives while the
        // form is already on screen, so changes are watched too.
        .onAppear { expandMoreOptionsIfNeeded() }
        .onChange(of: vm.notes) { expandMoreOptionsIfNeeded() }
        .onChange(of: vm.security) { expandMoreOptionsIfNeeded() }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            header
            AddProviderTemplateSection(vm: vm)
            nameSection
            if vm.providerID != nil {
                AddProviderFields(vm: vm, afterFilePicker: afterFilePicker)
            } else if let file = vm.sourceFile {
                fileRow(file)
            } else {
                KeyFieldsEditor(fields: $vm.fields)
            }
            moreOptions

            if let error = vm.errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }

            actions
        }
    }

    /// Opens the service-account file picker (also used by the form's "import a file instead").
    static func pickServiceAccountFile(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = L("Choose a service-account JSON file")
        panel.message = L("KeyKeeper will ask before reading and saving. The original file is not deleted.")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }

    private func fileRow(_ file: URL) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Key"), hint: L("stored in macOS Keychain"))
            HStack(spacing: 10) {
                Image(systemName: "doc.badge.gearshape").foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.lastPathComponent).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                    Text(L("Service-account JSON · read only after you confirm")).font(.caption2).foregroundColor(.secondary)
                }
                .help(file.path)
                Spacer()
                Button(L("Remove")) { vm.sourceFile = nil }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .surface(.inset, radius: DS.Radius.sm)
        }
    }

    private func save() {
        guard let file = vm.sourceFile else {
            if vm.save() {
                if let count = vm.clipboardChangeCount {
                    SecretPasteboard.clearIfUnchanged(since: count)
                }
                onSave()
            }
            return
        }
        guard let onImportFile else { return }
        isImporting = true
        let request = FileImportRequest(
            target: .init(credentialId: vm.credentialId, fieldName: "credentials-json", create: true),
            filePath: file.path
        )
        onImportFile(request) { result in
            isImporting = false
            if result.success { onSave() }
            else { vm.errorMessage = result.errorCode?.localizedDescription ?? L("File import failed.") }
        }
    }

    /// Only ever opens the section: collapsing is the user's decision to keep.
    private func expandMoreOptionsIfNeeded() {
        if !vm.notes.isEmpty || vm.expires != nil || vm.security != SecurityLevelPresentation.defaultLevel {
            showMoreOptions = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            if layout == .popover {
                PopoverBackButton(action: onCancel)
            }
            Text(L("Add a key")).font(layout == .embedded ? .system(size: 22, weight: .bold) : .headline)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: L("Name"))
            TextField("OpenAI", text: $vm.label)
                .textFieldStyle(.roundedBorder)
                .onChange(of: vm.label) { vm.autoGenerateId() }
            identityLine
        }
    }

    /// One line under the name that always occupies the same slot, so the form does not
    /// jump while typing. It shows the derived ID, or the reason it cannot be used.
    @ViewBuilder
    private var identityLine: some View {
        if isEditingId {
            TextField("stripe", text: Binding(
                get: { vm.credentialId },
                set: { vm.userEditedId($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.callout.monospaced())
        }

        if let conflict = vm.conflictingId {
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: "exclamationmark.circle")
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text(L("\(conflict) already exists"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button(L("Open it")) { onOpenExisting(conflict) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                if !isEditingId {
                    Button(L("Use another ID")) { isEditingId = true }
                        .buttonStyle(.plain)
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
                Spacer()
            }
        } else if let problem = vm.idFormatProblem, vm.hasDraft {
            Text(problem)
                .font(.caption2)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
        } else if !isEditingId {
            Button(action: { isEditingId = true }) {
                HStack(spacing: 4) {
                    Text(vm.idSummary)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                    Spacer()
                }
            }
            .buttonStyle(.plain)
            .help(L("Edit the ID that scripts and AI tools pass to keykeeper run -c"))
        }
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showMoreOptions) {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                DescriptionEditor(text: $vm.notes)
                ExpiryEditor(expires: $vm.expires)
                AdvancedSecuritySection(security: $vm.security, injectOnly: $vm.injectOnly)
                if onImportFile != nil, vm.sourceFile == nil, vm.providerID == nil {
                    Button(L("Import a service-account JSON file instead…")) {
                        Self.pickServiceAccountFile { vm.useFile($0); afterFilePicker() }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.accentColor)
                }
            }
            .padding(.top, DS.Spacing.sm)
        } label: {
            Text(L("More options"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            if vm.hasDraft {
                Button(L("Discard")) {
                    vm.reset()
                    isEditingId = false
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button(L("Save")) { save() }
            .disabled(!vm.isValid || isImporting)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Shared Subviews

struct DescriptionEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: L("Note for your agent"), hint: L("goes into the prompt"))
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 52, maxHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(6)
                .surface(.inset, radius: DS.Radius.sm)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(L("What it is for, limits, which environment\u{2026}"))
                            .font(.callout)
                            .foregroundColor(.secondary.opacity(0.5))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }
        }
    }
}

struct KeyFieldsEditor: View {
    @Binding var fields: [FieldEntry]
    /// Detail editor: the name column is the machine name and a separate display name is
    /// editable. Add form: whatever is typed becomes the display name and a machine name is
    /// derived from it.
    var showsDisplayName = false
    /// Called when a field that already holds a stored secret is switched to plain, so the
    /// editor can fetch the value first and ask the person to confirm.
    var onConvertToPlain: ((Int) -> Void)?
    /// Reads a field's stored value. Provided by the detail editor so the eye shows what is
    /// already saved; nil on the Add page, where nothing is stored yet.
    var revealStoredValue: ((FieldEntry) throws -> String)? = nil
    var onRevealError: ((Error) -> Void)? = nil

    /// Eye button behaviour, shared with the detail view. A stored value is fetched the
    /// first time it is revealed; before this, the edit-mode eye only flipped `visible`
    /// and showed an empty box, which read as "my key is gone".
    static func toggleVisibility(
        of fields: inout [FieldEntry],
        at index: Int,
        fetch: ((FieldEntry) throws -> String)?
    ) throws {
        guard fields.indices.contains(index), fields[index].fileFormat == nil else { return }
        if fields[index].visible {
            fields[index].visible = false
            return
        }
        if let fetch, fields[index].existingSecret, fields[index].value.isEmpty {
            fields[index].value = try fetch(fields[index])
        }
        fields[index].visible = true
    }

    /// "→ API_KEY", or "→ api-key · API_KEY" when the typed name gets a plainer machine name.
    private func namePreview(_ typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return " " }
        let machine = showsDisplayName ? trimmed : AddCredentialViewModel.machineFieldName(trimmed)
        let variable = EnvironmentVariableName.from(fieldName: machine)
        return machine == trimmed ? "\u{2192} \(variable)" : "\u{2192} \(machine) \u{00B7} \(variable)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: fields.count > 1 ? L("Keys") : L("Key"), hint: L("stored in macOS Keychain"))

            ForEach(fields.indices, id: \.self) { i in
                if fields[i].fileFormat != nil {
                    Label(L("\(fields[i].name) · Service-account JSON (contents hidden)"), systemImage: "doc.badge.gearshape")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                VStack(alignment: .leading, spacing: 2) {
                    // Name and value share one bordered container so the pair reads as one
                    // control, and the eye lives inside it rather than floating alongside.
                    HStack(spacing: 0) {
                        TextField(L("Name"), text: $fields[i].name)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .frame(width: 92)

                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 8)

                        if fields[i].isSecret {
                            MaskedValueField(
                                value: $fields[i].value,
                                visible: $fields[i].visible,
                                placeholder: fields[i].existingSecret
                                    ? L("Unchanged")
                                    : L("Paste or type the value"),
                                onToggleVisibility: { toggle(i) }
                            )
                        } else {
                            TextField(L("Plain value, e.g. an account id"), text: $fields[i].value)
                                .textFieldStyle(.plain)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        // File fields are always secret: their contents never leave the Keychain.
                        if fields[i].fileFormat == nil {
                            FieldKindMenu(isSecret: $fields[i].isSecret,
                                          hasStoredSecret: fields[i].existingSecret,
                                          onWantsPlain: { onConvertToPlain?(i) })
                        }

                        if fields.count > 1 {
                            Button(action: { fields.remove(at: i) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help(L("Remove this key"))
                            .padding(.leading, 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .surface(.inset, radius: DS.Radius.sm)

                    if showsDisplayName {
                        TextField(L("Display name (optional, for you and your agent)"), text: $fields[i].displayName)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                            .surface(.inset, radius: DS.Radius.sm)
                    }
                    // Rendered unconditionally: letting it appear and disappear made the
                    // whole form jump while the user was still typing the field name.
                    Text(namePreview(fields[i].name))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary.opacity(0.7))
                }
                }
            }

            Button(action: { fields.append(FieldEntry()) }) {
                Label(L("Add another key"), systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
    }
}

extension KeyFieldsEditor {
    fileprivate func toggle(_ index: Int) {
        do {
            try Self.toggleVisibility(of: &fields, at: index, fetch: revealStoredValue)
        } catch {
            onRevealError?(error)
        }
    }
}

struct AdvancedSecuritySection: View {
    @Binding var security: SecurityLevel
    /// Nil hides the toggle (screens that have no credential yet to apply it to).
    var injectOnly: Binding<Bool>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: SecurityLevelPresentation.sectionTitle)

            // yyt 2026-09-14: `get` to a pipe is a value in an agent's context. Off by default
            // for anything new; a person who runs the SDKs turns it on per credential.
            if let injectOnly {
                Toggle(isOn: Binding(get: { !injectOnly.wrappedValue }, set: { injectOnly.wrappedValue = !$0 })) {
                    Text(L("Can be read out (keykeeper get, SDKs)"))
                        .font(.subheadline)
                }
                Text(injectOnly.wrappedValue
                     ? L("Off: values only go into a command's environment through keykeeper run and are never printed or returned. An agent cannot get the value into its context.")
                     : L("On: keykeeper get and the SDKs return the value to whatever asked — including an AI agent's shell, where it lands in the model's context."))
                    .font(.caption2)
                    .foregroundColor(injectOnly.wrappedValue ? .secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: Binding(
                get: { security == .strict },
                set: { security = $0 ? .strict : .standard }
            )) {
                Text(SecurityLevelPresentation.strictToggleLabel)
                    .font(.subheadline)
            }

            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SecurityLevelPresentation.title(security))
                        .font(.caption.weight(.medium))
                    Text(SecurityLevelPresentation.detail(security))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: SecurityLevelPresentation.symbolName(security))
                    .foregroundColor(security == .strict ? .orange : .green)
            }
        }
    }
}


/// Picks how one field is stored. Two very different things, so the menu says both what it is
/// and where the value ends up — "plain" means readable by anything on this Mac.
struct FieldKindMenu: View {
    @Binding var isSecret: Bool
    var hasStoredSecret = false
    var onWantsPlain: (() -> Void)?

    var body: some View {
        Menu {
            Button {
                isSecret = true
            } label: {
                Label(L("Secret · stored in the Keychain"), systemImage: "lock.fill")
            }
            Button {
                // A stored secret needs its value in hand before it can move to plain text.
                if hasStoredSecret, let onWantsPlain { onWantsPlain() } else { isSecret = false }
            } label: {
                Label(L("Plain · readable by anything on this Mac"), systemImage: "doc.plaintext")
            }
        } label: {
            Image(systemName: isSecret ? "lock.fill" : "doc.plaintext")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isSecret ? L("Secret · stored in the Keychain") : L("Plain · readable by anything on this Mac"))
    }
}
