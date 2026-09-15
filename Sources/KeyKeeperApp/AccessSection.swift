import SwiftUI
import KeyKeeperCore

/// One approval, whichever store it came from. Terminal-session grants (strict
/// credentials) and background-caller grants (standard credentials) used to live in
/// two sections with two vocabularies; the user only cares "who can use this, for how long".
struct AccessEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case terminalSession
        case backgroundCaller
        case websiteLogin
    }

    let id: String
    let kind: Kind
    let who: String
    let scope: String
    let activity: String
    let isActive: Bool
    let sortDate: Date
    /// Everything behind the one line, for the disclosure. yyt 2026-09-15: "下钻展开看详情".
    var details: [Detail] = []

    struct Detail: Equatable {
        let label: String
        let value: String
    }

    var symbolName: String {
        switch kind {
        case .terminalSession: return "terminal"
        case .backgroundCaller: return "gearshape.2"
        case .websiteLogin: return "globe"
        }
    }
}

enum AccessEntryBuilder {
    static func entries(approvals: [Approval], now: Date = Date()) -> [AccessEntry] {
        approvals.map { approval in
            AccessEntry(
                id: "approval:\(approval.id)",
                kind: kind(approval),
                who: who(approval),
                scope: scopeLabel(approval, now: now),
                activity: approval.lastUsedAt.map { L("Used \(relative($0, now: now))") }
                    ?? L("Approved \(relative(approval.createdAt, now: now))"),
                isActive: isActive(approval, now: now),
                sortDate: approval.lastUsedAt ?? approval.createdAt,
                details: details(approval, now: now)
            )
        }
        .sorted { $0.sortDate > $1.sortDate }
    }

    static func details(_ approval: Approval, now: Date) -> [AccessEntry.Detail] {
        var rows: [AccessEntry.Detail] = []
        let assurance = CallerAssurance.of(CallerSubject(kind: .executable, fingerprint: approval.subject.fingerprint,
                                                         displayName: approval.subject.displayName, detail: ""))
        rows.append(.init(label: "Identity", value: identityWords(assurance)))
        if case .credential(_, let fields) = approval.target {
            rows.append(.init(label: "Keys", value: fields.map { $0.joined(separator: ", ") } ?? L("every secret field")))
        }
        if let reason = approval.reason, !reason.isEmpty {
            rows.append(.init(label: "Reason", value: CallerStatedReason.printableLine(reason, limit: 200)))
        }
        if let command = approval.command, !command.isEmpty {
            rows.append(.init(label: "Command", value: CallerStatedReason.printableLine(command, limit: 200)))
        }
        rows.append(.init(label: "Approved", value: absolute(approval.createdAt)))
        if let used = approval.lastUsedAt {
            rows.append(.init(label: "Last used", value: absolute(used)))
        }
        return rows
    }

    /// The tier in plain words: what this approval is actually tied to.
    static func identityWords(_ assurance: CallerAssurance) -> String {
        switch assurance {
        case .signed: return L("Signed app: this app and code it runs.")
        case .unsigned: return L("Unsigned: the file it runs from.")
        case .relayed: return L("Via the keykeeper command: the app or file it was started from.")
        case .unverified: return L("Unidentified: matches nobody.")
        }
    }

    private static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppL10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func kind(_ approval: Approval) -> AccessEntry.Kind {
        if case .session = approval.target { return .websiteLogin }
        if case .terminalSession = approval.duration { return .terminalSession }
        return .backgroundCaller
    }

    /// Who holds this approval. Display names are the caller's own words — sanitised like every
    /// other caller-supplied string.
    static func who(_ approval: Approval) -> String {
        let name = displayName(approval.subject.displayName) ?? L("Unknown Caller")
        if case .terminalSession(let id) = approval.duration, !id.isEmpty {
            return name + " · " + L("Terminal session \(id.prefix(8))")
        }
        return name
    }

    static func displayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = CallerStatedReason.printableLine(raw, limit: 80)
        return line.isEmpty ? nil : line
    }

    static func scopeLabel(_ approval: Approval, now: Date) -> String {
        let base: String
        switch approval.duration {
        case .once: base = L("Once")
        case .terminalSession: base = L("While that session is open")
        case .process: base = L("While it runs")
        case .timed(let date): base = date > now ? L("Until \(relative(date, now: now))") : L("Expired")
        case .always: base = L("Always")
        }
        if case .credential(_, let fields?) = approval.target, !fields.isEmpty {
            return "\(base) · \(fields.joined(separator: ", "))"
        }
        return base
    }

    /// Drawn as active only when it can still let somebody in. An unidentified owner matches
    /// nobody; a spent or expired one grants nothing.
    static func isActive(_ approval: Approval, now: Date) -> Bool {
        GrantIssuancePolicy.mayRemember(subjectFingerprint: approval.subject.fingerprint)
            && approval.isValid(now: now, ignoringTerminalSession: true)
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
    @State private var expanded: Set<String> = []

    private let approvals = ApprovalStore.shared

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
                        } else {
                            // In words: a missing dot was the only difference, and it read as "fine".
                            Text(L("No longer applies"))
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                        Button(L("Revoke")) { revoke(entry) }
                            .font(.caption)
                            .foregroundColor(.red)
                            .buttonStyle(.plain)
                        Button {
                            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
                        } label: {
                            Image(systemName: expanded.contains(entry.id) ? "chevron.down" : "chevron.right")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("Details"))
                    }
                    .padding(.vertical, 4)
                    if expanded.contains(entry.id) {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(entry.details, id: \.label) { detail in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(AppL10n.text(detail.label)).font(.caption2).foregroundColor(.secondary).frame(width: 64, alignment: .leading)
                                    Text(verbatim: detail.value).font(.caption2).textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 24)
                        .padding(.bottom, 6)
                    }

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
            entries = AccessEntryBuilder.entries(approvals: try approvals.approvals(forCredential: credentialId))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func revoke(_ entry: AccessEntry) {
        do {
            try approvals.revoke(id: String(entry.id.split(separator: ":", maxSplits: 1)[1]))
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
