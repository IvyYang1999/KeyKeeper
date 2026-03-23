import SwiftUI
import KeyKeeperCore

struct CredentialRow: View {
    let id: String
    let credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Text(credential.label)
                .font(.body.weight(.semibold))
                .lineLimit(1)

            let fieldNames = credential.fields.keys.sorted().joined(separator: ", ")
            if !fieldNames.isEmpty {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "key.fill")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(fieldNames)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if !credential.notes.isEmpty {
                Text(credential.notes)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.6))
                    .lineLimit(1)
            }

            Text(credential.updated)
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.4))
        }
        .dsCard(padding: DS.Spacing.md)
    }
}
