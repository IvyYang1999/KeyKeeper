import SwiftUI
import KeyKeeperCore

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

    @State private var showMoreOptions = false
    @State private var isEditingId = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                header
                nameSection
                KeyFieldsEditor(fields: $vm.fields)
                moreOptions

                if let error = vm.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                actions
            }
            .padding()
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
        // A deep link may carry notes, and a draft may have changed the access mode — in
        // both cases the collapsed section would be hiding something that was set for the
        // user. onAppear alone missed the case where a second deep link arrives while the
        // form is already on screen, so changes are watched too.
        .onAppear { expandMoreOptionsIfNeeded() }
        .onChange(of: vm.notes) { expandMoreOptionsIfNeeded() }
        .onChange(of: vm.security) { expandMoreOptionsIfNeeded() }
    }

    /// Only ever opens the section: collapsing is the user's decision to keep.
    private func expandMoreOptionsIfNeeded() {
        if !vm.notes.isEmpty || vm.security != SecurityLevelPresentation.defaultLevel {
            showMoreOptions = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            HStack {
                Button(action: onCancel) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                Spacer()
            }
            Text("Add a key").font(.headline)
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            SectionLabel(text: "Name")
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
                Text("\(conflict) already exists")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Button("Open it") { onOpenExisting(conflict) }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                if !isEditingId {
                    Button("Use another ID") { isEditingId = true }
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
            .help("Edit the ID that scripts and AI tools pass to keykeeper run -c")
        }
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showMoreOptions) {
            VStack(alignment: .leading, spacing: DS.Spacing.lg) {
                DescriptionEditor(text: $vm.notes)
                AdvancedSecuritySection(security: $vm.security)
            }
            .padding(.top, DS.Spacing.sm)
        } label: {
            Text("More options")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            if vm.hasDraft {
                Button("Discard") {
                    vm.reset()
                    isEditingId = false
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
            Button("Save") {
                if vm.save() { onSave() }
            }
            .disabled(!vm.isValid)
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
            SectionLabel(text: "Description", hint: "visible to AI")
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 52, maxHeight: 88)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .cornerRadius(DS.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("When to use these keys, renewal links, notes to self\u{2026}")
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

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: fields.count > 1 ? "Keys" : "Key", hint: "stored in macOS Keychain")

            ForEach(fields.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    // Name and value share one bordered container so the pair reads as one
                    // control, and the eye lives inside it rather than floating alongside.
                    HStack(spacing: 0) {
                        TextField("Name", text: $fields[i].name)
                            .textFieldStyle(.plain)
                            .font(.callout)
                            .frame(width: 92)

                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 8)

                        MaskedValueField(
                            value: $fields[i].value,
                            visible: $fields[i].visible,
                            placeholder: fields[i].existingSecret
                                ? "Unchanged"
                                : "Paste or type the value"
                        )

                        if fields.count > 1 {
                            Button(action: { fields.remove(at: i) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help("Remove this key")
                            .padding(.leading, 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: DS.Radius.sm)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )

                    // Rendered unconditionally: letting it appear and disappear made the
                    // whole form jump while the user was still typing the field name.
                    Text(fields[i].name.isEmpty
                         ? " "
                         : "\u{2192} \(EnvironmentVariableName.from(fieldName: fields[i].name))")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary.opacity(0.7))
                }
            }

            Button(action: { fields.append(FieldEntry()) }) {
                Label("Add another key", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)
        }
    }
}

struct AdvancedSecuritySection: View {
    @Binding var security: SecurityLevel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: SecurityLevelPresentation.sectionTitle)

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
