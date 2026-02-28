import SwiftUI
import KeyKeeperCore

struct CredentialRow: View {
    let id: String
    let credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(credential.label)
                .font(.headline)
            HStack(spacing: 8) {
                ForEach(Array(credential.fields.sorted(by: { $0.key < $1.key })), id: \.key) { name, field in
                    if field.secret {
                        Label(name, systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("\(name): \(field.value ?? "")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
