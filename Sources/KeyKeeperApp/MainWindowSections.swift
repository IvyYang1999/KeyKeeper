import SwiftUI
import KeyKeeperCore

/// Page header shared by the main window's non-key sections.
struct MainPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Access log

/// What KeyKeeper actually records: when an approved caller last used a key, and background
/// reads that happened without an approval or needed one. It is not a full audit trail, and
/// the page says so.
struct AccessLogEntry: Identifiable, Equatable {
    enum Kind: Equatable { case approvedUse, readWithoutApproval, approvalRequired }
    let id: String
    let date: Date
    let who: String
    let credentialId: String
    let detail: String
    let kind: Kind
    /// The subject as the store knows it: what an approval raised from this row would be for.
    var fingerprint: String = ""
    var reason: String?
    var command: String?
    /// For approved-use projections, this is the grant's structured scope, not a list of
    /// fields actually read. nil means all fields. Audit rows use their single `detail` field.
    var approvalFields: [String]?
}

enum AccessLogBuilder {
    static func entries(approvals: [Approval], auditEvents: [ServiceAuditEvent], limit: Int = 200) -> [AccessLogEntry] {
        let uses = approvals.compactMap { approval -> AccessLogEntry? in
            guard let used = approval.lastUsedAt, case .credential(let id, let fields) = approval.target else { return nil }
            return AccessLogEntry(id: "use:\(approval.id)", date: used,
                                  who: CallerStatedReason.printableLine(approval.subject.displayName, limit: 80),
                                  credentialId: id, detail: (fields ?? []).joined(separator: ", "),
                                  kind: .approvedUse, fingerprint: approval.subject.fingerprint,
                                  reason: approval.reason, command: approval.command, approvalFields: fields)
        }
        let events = auditEvents.enumerated().map { index, event in
            AccessLogEntry(id: "audit:\(index):\(event.timestamp.timeIntervalSince1970)", date: event.timestamp,
                           who: event.subjectDisplayName, credentialId: event.credentialId, detail: event.fieldName,
                           kind: event.decision == "allowed_without_grant" ? .readWithoutApproval : .approvalRequired,
                           fingerprint: event.subjectFingerprint, reason: event.reason, command: event.command)
        }
        return Array((uses + events).sorted { $0.date > $1.date }.prefix(limit))
    }

    /// One row per caller + key + field + kind: a script that reads the same key 255 times is
    /// one line with a count, not 255 lines.
    static func groups(_ entries: [AccessLogEntry]) -> [AccessLogGroup] {
        var order: [String] = []
        var byKey: [String: AccessLogGroup] = [:]
        for entry in entries {
            // Names are presentation, not identity. Unknown identities must not coalesce either.
            let subject = GrantIssuancePolicy.mayRemember(subjectFingerprint: entry.fingerprint) ? entry.fingerprint : entry.id
            // Structured scope avoids conflating ["a", "b"] with a field named "a, b".
            let scope = entry.kind == .approvedUse
                ? String(decoding: (try? JSONEncoder().encode(entry.approvalFields?.sorted())) ?? Data(), as: UTF8.self)
                : entry.detail
            let key = [subject, entry.credentialId, scope, "\(entry.kind)"].joined(separator: "\u{1F}")
            if var group = byKey[key] {
                group.count += 1
                group.entries.append(entry)
                if entry.date > group.latest {
                    group.latest = entry.date
                    group.reason = entry.reason ?? group.reason
                    group.command = entry.command ?? group.command
                }
                byKey[key] = group
            } else {
                order.append(key)
                byKey[key] = AccessLogGroup(id: key, who: entry.who, credentialId: entry.credentialId,
                                            detail: entry.detail, kind: entry.kind, count: 1, latest: entry.date,
                                            fingerprint: entry.fingerprint, reason: entry.reason, command: entry.command,
                                            entries: [entry], approvalFields: entry.approvalFields)
            }
        }
        return order.compactMap { byKey[$0] }.sorted {
            $0.latest != $1.latest ? $0.latest > $1.latest : $0.id < $1.id
        }
    }
}

struct AccessLogGroup: Identifiable, Equatable {
    let id: String
    let who: String
    let credentialId: String
    let detail: String
    let kind: AccessLogEntry.Kind
    var count: Int
    var latest: Date
    var fingerprint: String = ""
    var reason: String?
    var command: String?
    var entries: [AccessLogEntry] = []
    var approvalFields: [String]?
}

/// Shown while background reads need no approval ("permissive" mode, the default). It says
/// in plain words what "read without asking" means and offers the switch in place.
struct PermissiveModeBanner: View {
    var caption: String? = nil
    var onEnforce: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Background reads don't ask you right now"), systemImage: "exclamationmark.shield")
                .font(.callout.weight(.semibold))
            Text(L("Keys marked \"Background OK\" can be read by any script or agent on this Mac without a prompt. KeyKeeper only writes it down here as \"read without asking\". Turn on asking and each new caller is shown to you once; the ones you approve keep running unattended."))
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("Ask me first")) {
                    do {
                        try ApprovalStore.shared.setMode(.enforced)
                        errorMessage = nil
                        onEnforce()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.attention)
    }

    static var isPermissive: Bool {
        (try? ApprovalStore.shared.mode()) != .enforced
    }
}


struct EmptyGlassCard: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
