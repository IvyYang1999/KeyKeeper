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
                who: who(grant),
                scope: scopeLabel(grant.duration, now: now),
                activity: L("Approved \(relative(grant.createdAt, now: now))"),
                isActive: isActive(grant, now: now),
                sortDate: grant.createdAt
            )
        }
        let callerEntries = serviceGrants.map { grant in
            AccessEntry(
                id: "service:\(grant.id)",
                kind: .backgroundCaller,
                who: displayName(grant.subjectDisplayName) ?? L("Unknown Caller"),
                scope: scopeLabel(grant.duration, fields: grant.fields, now: now),
                activity: grant.lastUsedAt.map { L("Used \(relative($0, now: now))") }
                    ?? L("Approved \(relative(grant.createdAt, now: now))"),
                isActive: isActive(grant, now: now),
                sortDate: grant.lastUsedAt ?? grant.createdAt
            )
        }
        return (sessionEntries + callerEntries).sorted { $0.sortDate > $1.sortDate }
    }

    /// Who holds this approval. Display names are the caller's own words — sanitised like every
    /// other caller-supplied string, which this list used to draw straight through.
    static func who(_ grant: Grant) -> String {
        let place = sessionLabel(grant)
        guard let name = displayName(grant.subjectDisplayName) else { return place }
        if grant.sessionId == nil, case .always = grant.duration { return name }
        return name + " · " + place
    }

    static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = CallerStatedReason.printableLine(raw, limit: 80)
        return line.isEmpty ? nil : line
    }

    static func sessionLabel(_ grant: Grant) -> String {
        if case .session(let id) = grant.duration, !id.isEmpty {
            return L("Terminal session \(id.prefix(8))")
        }
        if let sessionId = grant.sessionId, !sessionId.isEmpty {
            return L("Terminal session \(sessionId.prefix(8))")
        }
        return L("Any terminal")
    }

    static func scopeLabel(_ duration: GrantDuration, now: Date) -> String {
        switch duration {
        case .once: return L("Once")
        case .session: return L("While that session is open")
        case .timed(let date): return date > now ? L("Until \(relative(date, now: now))") : L("Expired")
        case .always: return L("Always")
        }
    }

    static func scopeLabel(_ duration: ServiceGrantDuration, fields: [String], now: Date) -> String {
        let base: String
        switch duration {
        case .once: base = L("Once")
        case .timed(let date): base = date > now ? L("Until \(relative(date, now: now))") : L("Expired")
        case .always: base = L("Always")
        }
        return fields.isEmpty ? base : "\(base) · \(fields.joined(separator: ", "))"
    }

    static func isActive(_ grant: Grant, now: Date) -> Bool {
        // An approval with no owner, or an unidentified one, matches nobody any more. Drawing it
        // as an active "Always" would be the list lying about who can read what.
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: grant.subjectFingerprint) else { return false }
        switch grant.duration {
        case .once: return !grant.consumed
        case .session: return true
        case .timed(let date): return now < date
        case .always: return true
        }
    }

    static func isActive(_ grant: ServiceGrant, now: Date) -> Bool {
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: grant.subjectFingerprint) else { return false }
        if case .timed(let date) = grant.duration { return now < date }
        return true
    }

    private static func relative(_ date: Date, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppL10n.locale
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
            SectionLabel(text: L("Who is approved"), hint: security == .strict ? L("per terminal session") : L("per caller"))

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
                        Button(L("Revoke")) { revoke(entry) }
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
            return L("No one is approved yet. Each new terminal session that runs `keykeeper run -c \(credentialId)` will ask you.")
        case .standard:
            return L("No one is approved yet. The first script or agent that runs `keykeeper run -c \(credentialId)` will ask you once.")
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
