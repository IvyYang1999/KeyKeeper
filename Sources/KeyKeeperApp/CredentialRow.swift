import SwiftUI
import KeyKeeperCore

struct CredentialRow: View {
    let id: String
    let credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Name
            Text(credential.label)
                .font(.body.bold())
                .lineLimit(1)

            // Field names
            let fieldNames = credential.fields.keys.sorted().joined(separator: ", ")
            if !fieldNames.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(fieldNames)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            // Description (one line)
            if !credential.notes.isEmpty {
                Text(credential.notes)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
            }

            // Date
            Text(credential.updated)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.5))
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
