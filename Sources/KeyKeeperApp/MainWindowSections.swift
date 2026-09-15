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

// MARK: - Who can use them

/// Every approval across all keys, grouped by key, each revocable. This is the per-caller
/// model made visible: which process was trusted, for how long, and when it last used the key.
struct ApprovedCallersPage: View {
    let credentials: [(id: String, credential: Credential)]
    @State private var groups: [(id: String, label: String, entries: [AccessEntry])] = []
    @State private var errorMessage: String?
    @State private var permissive = false

    private let approvals = ApprovalStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MainPageHeader(
                    title: L("Who can use them"),
                    subtitle: L("Every script, agent or terminal session you have approved. Revoke one and it has to ask again.")
                )
                if permissive {
                    PermissiveModeBanner(onEnforce: load)
                }
                if groups.isEmpty {
                    EmptyGlassCard(
                        symbol: "checkmark.shield",
                        title: L("No one is approved yet"),
                        text: permissive
                            ? L("Terminal sessions you approve show up here. Background callers only appear once asking is turned on.")
                            : L("The first time a script or agent asks for a key, KeyKeeper asks you once. What you approve shows up here.")
                    )
                }
                ForEach(groups, id: \.id) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Text(group.label).font(.callout.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(group.entries.enumerated()), id: \.element.id) { index, entry in
                                entryRow(entry)
                                if index < group.entries.count - 1 {
                                    GlassSeparator()
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                        .glassCard()
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.caption).foregroundColor(.red)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12) // title lines up with the first sidebar item
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private func entryRow(_ entry: AccessEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.symbolName)
                .foregroundColor(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.who).lineLimit(1).truncationMode(.middle)
                Text("\(entry.scope) · \(entry.activity)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if entry.isActive {
                Circle().fill(.green).frame(width: 6, height: 6)
            }
            Button(L("Revoke")) { revoke(entry) }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
        }
        .font(.callout)
        .padding(.vertical, 9)
    }

    private func load() {
        permissive = PermissiveModeBanner.isPermissive
        do {
            groups = try credentials.compactMap { item in
                let entries = AccessEntryBuilder.entries(approvals: try approvals.approvals(forCredential: item.id))
                return entries.isEmpty ? nil : (item.id, item.credential.label, entries)
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
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
}

enum AccessLogBuilder {
    static func entries(approvals: [Approval], auditEvents: [ServiceAuditEvent], limit: Int = 200) -> [AccessLogEntry] {
        let uses = approvals.compactMap { approval -> AccessLogEntry? in
            guard let used = approval.lastUsedAt, case .credential(let id, let fields) = approval.target else { return nil }
            return AccessLogEntry(id: "use:\(approval.id)", date: used,
                                  who: CallerStatedReason.printableLine(approval.subject.displayName, limit: 80),
                                  credentialId: id, detail: (fields ?? []).joined(separator: ", "),
                                  kind: .approvedUse, fingerprint: approval.subject.fingerprint,
                                  reason: approval.reason, command: approval.command)
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
            let key = [entry.who, entry.credentialId, entry.detail, "\(entry.kind)"].joined(separator: "\u{1F}")
            if var group = byKey[key] {
                group.count += 1
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
                                            fingerprint: entry.fingerprint, reason: entry.reason, command: entry.command)
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

struct AccessLogPage: View {
    let credentials: [(id: String, credential: Credential)]
    @State private var groups: [AccessLogGroup] = []
    @State private var edits: [MetadataChangeRecord] = []
    @State private var permissive = false
    private let approvals = ApprovalStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MainPageHeader(
                    title: L("Access log"),
                    subtitle: L("Who read which key, newest first. Repeated reads are folded into one line. The last 500 background reads are kept.")
                )
                if permissive && groups.contains(where: { $0.kind == .readWithoutApproval }) {
                    PermissiveModeBanner(
                        caption: L("Callers below will each be asked once, the next time they read."),
                        onEnforce: load
                    )
                }
                if !edits.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L("Names and notes changed by agents")).font(.callout.weight(.semibold))
                        VStack(spacing: 0) {
                            ForEach(Array(edits.enumerated()), id: \.element.id) { index, record in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(MetadataEditCopy.headline(record)).lineLimit(1)
                                        Text(record.changes.map(MetadataEditCopy.text).joined(separator: " · "))
                                            .font(.caption).foregroundColor(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                    Text(relative(record.timestamp)).font(.caption).foregroundColor(.secondary)
                                }
                                .font(.callout)
                                .padding(.vertical, 9)
                                if index < edits.count - 1 { GlassSeparator() }
                            }
                        }
                        .padding(.horizontal, 14)
                        .glassCard()
                    }
                }
                if groups.isEmpty {
                    EmptyGlassCard(
                        symbol: "list.bullet.rectangle",
                        title: L("Nothing recorded yet"),
                        text: L("Uses by approved callers and background reads will appear here.")
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            row(group)
                            if index < groups.count - 1 {
                                GlassSeparator()
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .glassCard()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12) // title lines up with the first sidebar item
            .padding(.bottom, 24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .onAppear(perform: load)
    }

    private func load() {
        permissive = PermissiveModeBanner.isPermissive
        edits = Array(((try? MetadataChangeLog.default.records()) ?? []).suffix(20).reversed())
        groups = AccessLogBuilder.groups(AccessLogBuilder.entries(
            approvals: (try? approvals.all()) ?? [],
            auditEvents: (try? approvals.auditEvents()) ?? [],
            limit: .max
        ))
    }

    private func row(_ group: AccessLogGroup) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(group.who) · \(label(for: group.credentialId))").lineLimit(1).truncationMode(.middle)
                Text(group.detail).font(.caption.monospaced()).foregroundColor(.secondary)
                // yyt 2026-09-15: what it said and ran, right here — no second page.
                if let reason = group.reason, !reason.isEmpty {
                    Text(verbatim: "\u{201C}" + CallerStatedReason.printableLine(reason, limit: 120) + "\u{201D}")
                        .font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                }
                if let command = group.command, !command.isEmpty {
                    Text(verbatim: "$ " + CallerStatedReason.printableLine(command, limit: 120))
                        .font(.caption2.monospaced()).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            // A request nobody answered in time can be approved from here for the next call.
            if group.kind == .approvalRequired, let standing = standingRequest(group) {
                Button(L("Approve now")) { StandingApprovalRequester.shared.handler?(standing) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            tag(group.kind)
            Text(group.count > 1 ? L("\(group.count) times") : "")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
            Text(relative(group.latest)).font(.caption).foregroundColor(.secondary)
                .frame(minWidth: 70, alignment: .trailing)
        }
        .font(.callout)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private func tag(_ kind: AccessLogEntry.Kind) -> some View {
        switch kind {
        case .approvedUse:
            Text(L("Approved caller")).font(.caption2.weight(.semibold)).foregroundColor(.green)
        case .readWithoutApproval:
            Text(L("Read without asking")).font(.caption2.weight(.semibold)).foregroundColor(.orange)
                .help(L("Background access is set to not ask, so this read went through without a prompt."))
        case .approvalRequired:
            Text(L("Asked for approval")).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
        }
    }

    private func label(for id: String) -> String {
        (credentials.first { $0.id == id } ?? credentials.first { $0.credential.aliases?.contains(id) == true })?
            .credential.label ?? id
    }

    private func standingRequest(_ group: AccessLogGroup) -> StandingApprovalRequest? {
        let credential = (credentials.first { $0.id == group.credentialId } ?? credentials.first { $0.credential.aliases?.contains(group.credentialId) == true })?.credential
        let fields = credential.map { $0.fields.filter(\.value.secret).map(\.key).sorted() } ?? [group.detail]
        return StandingApprovalRequest(group: group, credentialLabel: label(for: group.credentialId), fieldNames: fields)
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppL10n.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
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
