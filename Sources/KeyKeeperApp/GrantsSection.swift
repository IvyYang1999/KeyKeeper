import SwiftUI
import KeyKeeperCore

struct GrantsSection: View {
    let credentialId: String
    @State private var grants: [Grant] = []
    @State private var errorMessage: String?

    private let grantStore = GrantStore.default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Access Grants").font(.subheadline.bold())

            if grants.isEmpty {
                Text("No active grants")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(grants) { grant in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(durationLabel(grant.duration))
                                .font(.callout)
                            Text("Created \(formatDate(grant.createdAt))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if isActive(grant) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                        }

                        Button("Revoke") {
                            revoke(grant.id)
                        }
                        .font(.caption)
                        .foregroundColor(.red)
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)

                    if grant.id != grants.last?.id {
                        Divider()
                    }
                }
            }

            if let error = errorMessage {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
        .onAppear { loadGrants() }
    }

    private func loadGrants() {
        do {
            grants = try grantStore.grants(for: credentialId)
                .sorted { $0.createdAt > $1.createdAt }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ grantId: String) {
        do {
            try grantStore.revokeGrant(id: grantId)
            loadGrants()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isActive(_ grant: Grant) -> Bool {
        switch grant.duration {
        case .once: return !grant.consumed
        case .session: return true  // can't easily verify session from app side
        case .timed(let date): return Date() < date
        case .always: return true
        }
    }

    private func durationLabel(_ duration: GrantDuration) -> String {
        switch duration {
        case .once: return "One-time"
        case .session(let id): return "Session (\(String(id.prefix(8))))"
        case .timed(let date):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return "Until \(formatter.localizedString(for: date, relativeTo: Date()))"
        case .always: return "Always"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
