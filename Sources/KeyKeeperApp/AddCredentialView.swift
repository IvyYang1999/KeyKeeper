import SwiftUI
import KeyKeeperCore

struct AddCredentialView: View {
    @ObservedObject var vm: AddCredentialViewModel
    var onSave: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with back
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

                Text("New Key Group").font(.headline)

                // 1. Name
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    SectionLabel(text: "Name")
                    TextField("e.g. Feishu Bot, Stripe, OpenAI", text: $vm.label)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: vm.label) { vm.autoGenerateId() }
                }

                // 1b. ID — what scripts and AI tools pass to `keykeeper run -c`
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    SectionLabel(text: "ID", hint: "used as keykeeper run -c <id>")
                    TextField("stripe", text: Binding(
                        get: { vm.credentialId },
                        set: { vm.userEditedId($0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    if vm.hasDraft, let problem = vm.idProblem {
                        Text(problem)
                            .font(.caption2)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // 2. Description
                DescriptionEditor(text: $vm.notes)

                // 3. Keys
                KeyFieldsEditor(fields: $vm.fields)

                // 4. Advanced
                AdvancedSecuritySection(security: $vm.security)

                // Error
                if let error = vm.errorMessage {
                    Text(error).font(.caption).foregroundColor(.red)
                }

                // Buttons
                HStack {
                    Button("Discard") {
                        vm.reset()
                        onCancel()
                    }
                    .foregroundColor(.red)
                    Spacer()
                    Button("Save") {
                        if vm.save() {
                            onSave()
                        }
                    }
                    .disabled(!vm.isValid)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: DS.Popover.width, height: DS.Popover.height)
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
                .frame(minHeight: 60, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(DS.Radius.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                )
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("Tell AI when to use these keys, and add notes for yourself (renewal links, docs, etc.)")
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
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Keys", hint: "values stored in encrypted vault")

            ForEach(fields.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TextField("Name", text: $fields[i].name)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 100)

                        MaskedValueField(
                            value: $fields[i].value,
                            visible: $fields[i].visible
                        )

                        if fields.count > 1 {
                            Button(action: { fields.remove(at: i) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .help("Remove this key")
                        }
                    }

                    if !fields[i].name.isEmpty {
                        Text("\u{2192} \(EnvironmentVariableName.from(fieldName: fields[i].name)) in keykeeper run")
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
            }

            Button(action: { fields.append(FieldEntry()) }) {
                Label("Add Key", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Text("Names are visible to AI. Values are encrypted in the vault — AI never sees them.")
                .font(.caption2)
                .foregroundColor(.secondary)
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
