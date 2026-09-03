import SwiftUI
import KeyKeeperCore

/// One approval, whichever store it came from. Terminal-session grants (strict
/// credentials) and background-caller grants (standard credentials) used to live in
/// two sections with two vocabularies; the user only cares "who can use this, for how long".
struct AccessEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminalSession
        case backgroundCaller
    }

    let id: String
    let kind: Kind
    let who: String
    let scope: String
    let activity: String
    let isActive: Bool
    let sortDate: Date

    var symbolName: String {
        switch kind {
        case .terminalSession: return "terminal"
        case .backgroundCaller: return "gearshape.2"
        }
    }
}

enum AccessEntryBuilder {
    static func entries(grants: [Grant], serviceGrants: [ServiceGrant], now: Date = Date()) -> [AccessEntry] {
        let sessionEntries = grants.map { grant in
            AccessEntry(
                id: "grant:\(grant.id)",
                kind: .terminalSession,
                who: sessionLabel(grant),
                scope: scopeLabel(grant.duration, now: now),
                activity: "Approved \(relative(grant.createdAt, now: now))",
                isActive: isActive(grant, now: now),
                sortDate: grant.createdAt
            )
        }
        let callerEntries = serviceGrants.map { grant in
            AccessEntry(
                id: "service:\(grant.id)",
                kind: .backgroundCaller,
                who: grant.subjectDisplayName,
                scope: scopeLabel(grant.duration, fields: grant.fields, now: now),
                activity: grant.lastUsedAt.map { "Used \(relative($0, now: now))" }
                    ?? "Approved \(relative(grant.createdAt, now: now))",
                isActive: isActive(grant, now: now),
                sortDate: grant.lastUsedAt ?? grant.createdAt
            )
        }
        return (sessionEntries + callerEntries).sorted { $0.sortDate > $1.sortDate }
    }

    static func sessionLabel(_ grant: Grant) -> String {
        if case .session(let id) = grant.duration, !id.isEmpty {
            return "Terminal session \(id.prefix(8))"
        }
        if let sessionId = grant.sessionId, !sessionId.isEmpty {
            return "Terminal session \(sessionId.prefix(8))"
        }
        return "Any terminal"
    }

    static func scopeLabel(_ duration: GrantDuration, now: Date) -> String {
        switch duration {
        case .once: return "Once"
        case .session: return "While that session is open"
        case .timed(let date): return date > now ? "Until \(relative(date, now: now))" : "Expired"
        case .always: return "Always"
        }
    }

    static func scopeLabel(_ duration: ServiceGrantDuration, fields: [String], now: Date) -> String {
        let base: String
        switch duration {
        case .once: base = "Once"
        case .timed(let date): base = date > now ? "Until \(relative(date, now: now))" : "Expired"
        case .always: base = "Always"
        }
        return fields.isEmpty ? base : "\(base) · \(fields.joined(separator: ", "))"
    }

    static func isActive(_ grant: Grant, now: Date) -> Bool {
        switch grant.duration {
        case .once: return !grant.consumed
        case .session: return true
        case .timed(let date): return now < date
        case .always: return true
        }
    }

    static func isActive(_ grant: ServiceGrant, now: Date) -> Bool {
        if case .timed(let date) = grant.duration { return now < date }
        return true
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

struct AccessSection: View {
    let credentialId: String
    let security: SecurityLevel
    @State private var entries: [AccessEntry] = []
    @State private var errorMessage: String?

    private let grantStore = GrantStore.default
    private let serviceGrantStore = ServiceGrantStore.default

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: "Who is approved", hint: security == .strict ? "per terminal session" : "per caller")

            if entries.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .top) {
                        Image(systemName: entry.symbolName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.who)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(entry.scope)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(entry.activity)
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.7))
                        }
                        Spacer()
                        if entry.isActive {
                            Circle().fill(.green).frame(width: 6, height: 6)
                                .padding(.top, 6)
                        }
                        Button("Revoke") { revoke(entry) }
                            .font(.caption)
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)

                    if entry.id != entries.last?.id {
                        Divider()
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .onAppear(perform: load)
    }

    private var emptyText: String {
        switch security {
        case .strict:
            return "No one is approved yet. Each new terminal session that runs `keykeeper run -c \(credentialId)` will ask you."
        case .standard:
            return "No one is approved yet. The first script or agent that runs `keykeeper run -c \(credentialId)` will ask you once."
        }
    }

    private func load() {
        do {
            entries = AccessEntryBuilder.entries(
                grants: try grantStore.grants(for: credentialId),
                serviceGrants: try serviceGrantStore.grants(credentialId: credentialId)
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ entry: AccessEntry) {
        do {
            let rawId = String(entry.id.split(separator: ":", maxSplits: 1)[1])
            switch entry.kind {
            case .terminalSession: try grantStore.revokeGrant(id: rawId)
            case .backgroundCaller: try serviceGrantStore.revokeGrant(id: rawId)
            }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
