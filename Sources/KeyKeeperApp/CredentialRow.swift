import SwiftUI
import KeyKeeperCore

struct CredentialRow: View {
    let id: String
    let credential: Credential

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(credential.label)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.sm)
                SecurityBadge(level: credential.security)
            }

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

            Text("Updated \(credential.updated)")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.4))
        }
        .dsCard(padding: DS.Spacing.md)
    }
}

/// Compact "who can use this" marker, shown wherever a credential is listed.
struct SecurityBadge: View {
    let level: SecurityLevel

    var body: some View {
        Label(SecurityLevelPresentation.badge(level), systemImage: SecurityLevelPresentation.symbolName(level))
            .font(.caption2.weight(.medium))
            .foregroundColor(level == .strict ? .orange : .green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (level == .strict ? Color.orange : Color.green).opacity(0.12),
                in: Capsule()
            )
            .help(SecurityLevelPresentation.detail(level))
    }
}
