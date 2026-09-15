import SwiftUI
import KeyKeeperCore
import UniformTypeIdentifiers

/// Reuses the catalog browser; template selection only edits this unsaved draft.
struct AddProviderTemplateSection: View {
    @ObservedObject var vm: AddCredentialViewModel
    @State private var pendingSelection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Provider template"), hint: L("optional"))
            ProviderPickerButton(selection: Binding(
                get: { vm.providerID ?? "" },
                set: { if !vm.selectProvider($0) { pendingSelection = $0 } }
            ))
            if vm.providerID != nil {
                ProviderManagementLink(providerID: vm.providerID)
            } else {
                Text(L("Choose a provider to fill in its fields, or enter a key manually below."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert(L("Change template?"), isPresented: Binding(
            get: { pendingSelection != nil },
            set: { if !$0 { pendingSelection = nil } }
        )) {
            Button(L("Cancel"), role: .cancel) { pendingSelection = nil }
            Button(L("Clear values and change"), role: .destructive) {
                if let id = pendingSelection { vm.selectProvider(id, discardValues: true) }
                pendingSelection = nil
            }
        } message: {
            Text(L("This clears the unsaved key values and file selections on this page. Your saved credentials are not affected."))
        }
    }
}

/// Names and storage kinds are fixed by the chosen contract. A secret cannot accidentally
/// become public metadata, and a credential file cannot turn into an ordinary text field.
struct AddProviderFields: View {
    @ObservedObject var vm: AddCredentialViewModel
    var afterFilePicker: () -> Void

    var body: some View {
        if let template = vm.provider {
            VStack(alignment: .leading, spacing: DS.Spacing.md) {
                if template.fields.contains(where: { $0.kind == .localIdentity }) {
                    Label(L("This is a signing identity in the macOS Keychain, not an API key. Manage it with Apple; do not paste or export its private key here."),
                          systemImage: "key.horizontal")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(vm.fields.indices, id: \.self) { index in
                        if let field = template.field(named: vm.fields[index].name) {
                            fieldRow(field, index: index)
                        }
                    }
                    if let problem = vm.providerProblem {
                        Text(problem).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("Save checks required fields and documented formats, not whether the provider accepts the key."))
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup(L("Template guidance")) {
                    VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        Text(template.minimalPermission)
                        ProviderExpiryPolicyLine(providerId: template.id)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.sm)
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func fieldRow(_ field: ProviderFieldTemplate, index: Int) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppL10n.text(field.label)).font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(field.required ? L("Required") : L("optional"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: field.isSaveableSecret ? "lock.fill" : "doc.plaintext")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(field.isSaveableSecret ? L("Secret · stored in the Keychain") : L("Plain · readable by anything on this Mac"))
            }
            if field.kind == .secretFile {
                fileRow(field)
            } else if field.kind == .secretText {
                MaskedValueField(value: $vm.fields[index].value, visible: $vm.fields[index].visible,
                                 placeholder: L("Paste or type the value"),
                                 onToggleVisibility: { vm.fields[index].visible.toggle() })
                    .padding(8).surface(.inset, radius: DS.Radius.sm)
                    .accessibilityIdentifier("provider-field-" + field.name)
            } else {
                TextField(L("Plain value, e.g. an account id"), text: $vm.fields[index].value)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("provider-field-" + field.name)
            }
            Text(field.environmentNames.joined(separator: " · "))
                .font(.caption2.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(field.help)
    }

    private func fileRow(_ field: ProviderFieldTemplate) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack {
                if let file = vm.providerFiles[field.name] {
                    Label(file.lastPathComponent, systemImage: "doc.badge.gearshape")
                        .lineLimit(1).truncationMode(.middle).help(file.path)
                    Spacer()
                    Button(L("Remove")) { vm.removeProviderFile(field.name) }.buttonStyle(.borderless)
                } else {
                    Button(L("Choose credential file…")) { pickFile(field) }
                        .accessibilityIdentifier("provider-file-" + field.name)
                    Spacer()
                }
            }
            Text(L("Read only when you click Save. The original file is kept."))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func pickFile(_ field: ProviderFieldTemplate) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = field.fileFormat == .applePrivateKeyP8
            ? [UTType(filenameExtension: "p8") ?? .data] : [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = AppL10n.text(field.label)
        panel.message = L("Read only when you click Save. The original file is kept.")
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            if response == .OK, let url = panel.url { vm.setProviderFile(url, fieldName: field.name) }
            afterFilePicker()
        }
    }
}
