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
                KeyFieldsEditor(fields: $vm.fields, errors: vm.fieldErrors)
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
                .dsInput()
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
            .dsInput(monospaced: true)
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
                        // Monospaced only for the ID and command; the "generated from the name"
                        // sentence in a code font looked like a broken label.
                        .font(vm.credentialId.isEmpty ? .caption2 : .caption2.monospaced())
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

/// The keys of one credential as a single grouped card, one row per key: its name, its value,
/// and a ⋯ menu for the rare things. Shared by the Add form and the detail editor.
///
/// 【曾经的 bug】2026-11-07 yyt：编辑页一个字段占三行（名称｜值、显示名、→ 环境变量名），已存的值只写
/// 「未修改」，每行挤着眼睛、锁、减号三个灰图标；名字填错格子还会连值一起丢。Now a row is one line
/// the person reads as "name — value": they write one name, the script name is derived and shown
/// small underneath, and a saved value shows its masked look instead of "unchanged".
struct KeyFieldsEditor: View {
    @Binding var fields: [FieldEntry]
    /// Detail editor: rows may already exist, the name written is the display wording and the
    /// field name can be changed from the ⋯ menu. Add form: what is typed is the name, and the
    /// field name is derived from it when saving.
    var showsDisplayName = false
    /// Called when a field that already holds a stored secret is switched to plain, so the
    /// editor can fetch the value first and ask the person to confirm.
    var onConvertToPlain: ((Int) -> Void)?
    /// Reads a field's stored value. Provided by the detail editor so the eye shows what is
    /// already saved; nil on the Add page, where nothing is stored yet.
    var revealStoredValue: ((FieldEntry) throws -> String)? = nil
    var onRevealError: ((Error) -> Void)? = nil
    /// Problems shown under a row, keyed by `FieldEntry.id`.
    var errors: [UUID: String] = [:]

    @Environment(\.panelLayout) private var layout

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

    /// The small line under a row's name: the name scripts use and the variable it becomes.
    /// "→ API_KEY" when the written name is already the script name, else "api-key → API_KEY".
    static func scriptLine(machineName: String, title: String, isSecret: Bool) -> String {
        guard !machineName.isEmpty else { return " " }
        let variable = EnvironmentVariableName.from(fieldName: machineName)
        let line = machineName == title ? "\u{2192} \(variable)" : "\(machineName) \u{2192} \(variable)"
        return isSecret ? line : line + " \u{00B7} " + L("plain text")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: fields.count > 1 ? L("Keys") : L("Key"), hint: L("stored in macOS Keychain"))

            VStack(spacing: 0) {
                ForEach($fields) { $field in
                    if field.id != fields.first?.id { GlassSeparator().padding(.leading, 12) }
                    KeyFieldRow(
                        field: $field,
                        showsDisplayName: showsDisplayName,
                        nameWidth: layout == .embedded ? 190 : 136,
                        error: errors[field.id],
                        canRemove: fields.count > 1,
                        onToggleVisibility: { toggle(field.id) },
                        onWantsPlain: {
                            if field.existingSecret, let onConvertToPlain, let index = index(of: field.id) {
                                onConvertToPlain(index)
                            } else {
                                field.isSecret = false
                            }
                        },
                        onRemove: { remove(field.id) }
                    )
                }
            }
            .surface(.card, radius: DS.Radius.md)

            Button(action: { fields.append(FieldEntry()) }) {
                Label(L("Add another key"), systemImage: "plus.circle")
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
            .padding(.leading, 2)
        }
    }

    private func index(of id: UUID) -> Int? { fields.firstIndex { $0.id == id } }

    private func remove(_ id: UUID) {
        guard fields.count > 1, let index = index(of: id) else { return }
        fields.remove(at: index)
    }
}

extension KeyFieldsEditor {
    fileprivate func toggle(_ id: UUID) {
        guard let index = index(of: id) else { return }
        do {
            try Self.toggleVisibility(of: &fields, at: index, fetch: revealStoredValue)
        } catch {
            onRevealError?(error)
        }
    }
}

/// One key: [name / script name] | [value] [eye] [⋯].
private struct KeyFieldRow: View {
    @Binding var field: FieldEntry
    let showsDisplayName: Bool
    let nameWidth: CGFloat
    let error: String?
    let canRemove: Bool
    let onToggleVisibility: () -> Void
    let onWantsPlain: () -> Void
    let onRemove: () -> Void

    @State private var renaming = false
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    /// The one name the person writes. On Add it is the field itself (the script name is
    /// derived when saving); in the editor it is the wording, see `FieldEntry.setTitle`.
    private var title: Binding<String> {
        showsDisplayName
            ? Binding(get: { field.title }, set: { field.setTitle($0) })
            : $field.name
    }

    private var scriptLine: String {
        if showsDisplayName {
            return KeyFieldsEditor.scriptLine(machineName: field.name, title: field.title, isSecret: field.isSecret)
        }
        let typed = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return KeyFieldsEditor.scriptLine(
            machineName: typed.isEmpty ? "" : AddCredentialViewModel.machineFieldName(typed),
            title: typed, isSecret: field.isSecret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(L("Name"), text: title)
                        .textFieldStyle(.plain)
                        .font(.body)
                    Text(scriptLine)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(L("The name scripts and agents use, and the environment variable it becomes."))
                }
                .frame(width: nameWidth, alignment: .leading)

                Rectangle()
                    .fill(Glass.separator(scheme))
                    .frame(width: 1, height: 26)

                value
                    .frame(maxWidth: .infinity, alignment: .leading)

                menu
            }

            if renaming {
                fieldNameEditor
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var value: some View {
        if field.fileFormat != nil {
            Label(L("Service-account JSON (contents hidden)"), systemImage: "doc.badge.gearshape")
                .font(.callout)
                .foregroundColor(.secondary)
        } else if !field.isSecret {
            TextField(L("Plain value, e.g. an account id"), text: $field.value)
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
        } else if field.existingSecret, field.value.isEmpty, !field.replacing {
            savedValue
        } else {
            HStack(spacing: 6) {
                MaskedValueField(
                    value: $field.value,
                    visible: $field.visible,
                    placeholder: field.existingSecret ? L("Paste the new value") : L("Paste or type the value"),
                    focusOnAppear: field.replacing,
                    onToggleVisibility: onToggleVisibility
                )
                if field.existingSecret {
                    Button {
                        field.value = ""
                        field.visible = false
                        field.replacing = false
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Keep the saved value"))
                }
            }
        }
    }

    /// A stored secret nobody has touched: its masked look, or a clear "missing".
    /// Clicking it starts typing a replacement; the eye reads the stored value.
    private var savedValue: some View {
        HStack(spacing: 8) {
            // The menu bar is narrow: the short form when the full one does not fit.
            if field.storedMissing {
                ViewThatFits(in: .horizontal) {
                    missingLabel(L("No value stored. Paste it here."))
                    missingLabel(L("Value missing"))
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        preview
                        Text(hovering ? L("Replace") : L("Saved"))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(hovering ? .accentColor : .secondary)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.06)))
                    }
                    preview
                }
            }
            Spacer(minLength: 4)
            if !field.storedMissing {
                Button(action: onToggleVisibility) {
                    Image(systemName: "eye")
                        .foregroundColor(.secondary)
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                .help(L("Show value"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { field.replacing = true }
        .help(L("Click to replace this value"))
    }

    private var preview: some View {
        Text(field.storedPreview ?? ValueHintText.masked(nil))
            .font(.callout.monospaced())
            .lineLimit(1)
            .fixedSize()
    }

    private func missingLabel(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundColor(.orange)
            .lineLimit(1)
            .fixedSize()
    }

    private var menu: some View {
        Menu {
            if showsDisplayName {
                Button(L("Change field name\u{2026}")) { renaming = true }
            }
            if field.fileFormat == nil {
                if field.isSecret {
                    Button(L("Store as plain text\u{2026}"), action: onWantsPlain)
                } else {
                    Button(L("Store as a secret")) { field.isSecret = true }
                }
            }
            if canRemove {
                Divider()
                Button(L("Remove this key"), role: .destructive, action: onRemove)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("More"))
    }

    /// "Change field name": the script name, for the few who need a specific one.
    private var fieldNameEditor: some View {
        HStack(spacing: 8) {
            Text(L("Field name"))
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("api-key", text: Binding(get: { field.name }, set: { field.setMachineName($0) }))
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .padding(.horizontal, 6)
                .frame(width: 180, height: 22)
                .surface(.inset, radius: 6)
            Text(field.originalName == nil
                 ? L("Scripts use this name.")
                 : L("Scripts use this name; the old one keeps working."))
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L("Done")) { renaming = false }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
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
