import SwiftUI
import KeyKeeperCore

struct AddCredentialView: View {
    @StateObject private var vm = AddCredentialViewModel()
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add Credential").font(.headline)

                TextField("Label", text: $vm.label)
                    .onChange(of: vm.label) {
                        vm.autoGenerateId()
                    }
                TextField("ID", text: $vm.credentialId)
                    .font(.caption)
                TextField("Notes", text: $vm.notes, axis: .vertical)
                    .lineLimit(3)

                Divider()

                Text("Links").font(.subheadline.bold())
                ForEach(vm.links.indices, id: \.self) { i in
                    TextField("URL", text: $vm.links[i])
                }
                Button("+ Add Link") { vm.links.append("") }
                    .font(.caption)

                Divider()

                Text("Fields").font(.subheadline.bold())
                ForEach(vm.fields.indices, id: \.self) { i in
                    HStack {
                        TextField("Name", text: $vm.fields[i].name)
                            .frame(width: 100)
                        if vm.fields[i].isSecret {
                            SecureField("Value", text: $vm.fields[i].value)
                        } else {
                            TextField("Value", text: $vm.fields[i].value)
                        }
                        Button(action: {
                            vm.fields[i].isSecret.toggle()
                        }) {
                            Image(systemName: vm.fields[i].isSecret ? "lock.fill" : "lock.open")
                        }
                        .help(vm.fields[i].isSecret ? "Secret (stored in Keychain)" : "Plain text")
                    }
                }
                Button("+ Add Field") { vm.fields.append(FieldEntry()) }
                    .font(.caption)

                Divider()

                Picker("Security", selection: $vm.security) {
                    Text("Standard").tag(SecurityLevel.standard)
                    Text("Strict (Touch ID)").tag(SecurityLevel.strict)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("Cancel") { dismiss() }
                    Spacer()
                    Button("Save") {
                        try? vm.save()
                        onSave()
                        dismiss()
                    }
                    .disabled(!vm.isValid)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 520)
    }
}
