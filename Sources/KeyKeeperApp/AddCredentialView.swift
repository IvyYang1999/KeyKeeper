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
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name").font(.subheadline.bold())
                    TextField("e.g. Feishu Bot, Stripe, OpenAI", text: $vm.label)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: vm.label) { vm.autoGenerateId() }
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
                        do {
                            try vm.save()
                            onSave()
                        } catch {
                            vm.errorMessage = "Save failed: \(error.localizedDescription)"
                        }
                    }
                    .disabled(!vm.isValid)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 380, height: 480)
    }
}

// MARK: - Shared Subviews

struct DescriptionEditor: View {
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Description").font(.subheadline.bold())
                Text("visible to AI").font(.caption).foregroundColor(.secondary)
            }
            TextEditor(text: $text)
                .font(.callout)
                .frame(minHeight: 60, maxHeight: 100)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
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
            HStack(alignment: .firstTextBaseline) {
                Text("Keys").font(.subheadline.bold())
                Text("values stored in Keychain").font(.caption).foregroundColor(.secondary)
            }

            ForEach(fields.indices, id: \.self) { i in
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
                    }
                }
            }

            Button(action: { fields.append(FieldEntry()) }) {
                Label("Add Key", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Text("Names are visible to AI. Values are encrypted in Keychain — AI never sees them.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

struct AdvancedSecuritySection: View {
    @Binding var security: SecurityLevel

    var body: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { security == .strict },
                    set: { security = $0 ? .strict : .standard }
                )) {
                    Text("Require authentication every time")
                        .font(.subheadline)
                }

                if security == .strict {
                    Text("Each access requires Touch ID or password. This is the safest option.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    Label {
                        Text("macOS will remember access after the first authorization. Less secure — only disable this if you understand the risk.")
                            .font(.caption2)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.caption2)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }
}
