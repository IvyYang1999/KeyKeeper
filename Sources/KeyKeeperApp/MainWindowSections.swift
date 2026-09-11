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

    private let grantStore = GrantStore.default
    private let serviceGrantStore = ServiceGrantStore.default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MainPageHeader(
                    title: L("Who can use them"),
                    subtitle: L("Every script, agent or terminal session you have approved. Revoke one and it has to ask again.")
                )
                if groups.isEmpty {
                    EmptyGlassCard(
                        symbol: "checkmark.shield",
                        title: L("No one is approved yet"),
                        text: L("The first time a script or agent asks for a key, KeyKeeper asks you once. What you approve shows up here.")
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
        do {
            groups = try credentials.compactMap { item in
                let entries = AccessEntryBuilder.entries(
                    grants: try grantStore.grants(for: item.id),
                    serviceGrants: try serviceGrantStore.grants(credentialId: item.id)
                )
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
}

enum AccessLogBuilder {
    static func entries(serviceGrants: [ServiceGrant], auditEvents: [ServiceAuditEvent], limit: Int = 200) -> [AccessLogEntry] {
        let uses = serviceGrants.compactMap { grant -> AccessLogEntry? in
            guard let used = grant.lastUsedAt else { return nil }
            return AccessLogEntry(id: "use:\(grant.id)", date: used, who: grant.subjectDisplayName,
                                  credentialId: grant.credentialId, detail: grant.fields.joined(separator: ", "),
                                  kind: .approvedUse)
        }
        let events = auditEvents.enumerated().map { index, event in
            AccessLogEntry(id: "audit:\(index):\(event.timestamp.timeIntervalSince1970)", date: event.timestamp,
                           who: event.subjectDisplayName, credentialId: event.credentialId, detail: event.fieldName,
                           kind: event.decision == "allowed_without_grant" ? .readWithoutApproval : .approvalRequired)
        }
        return Array((uses + events).sorted { $0.date > $1.date }.prefix(limit))
    }
}

struct AccessLogPage: View {
    let credentials: [(id: String, credential: Credential)]
    @State private var entries: [AccessLogEntry] = []
    private let serviceGrantStore = ServiceGrantStore.default

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                MainPageHeader(
                    title: L("Access log"),
                    subtitle: L("When approved callers last used a key, and background reads that needed or skipped an approval. Up to 500 events are kept.")
                )
                if entries.isEmpty {
                    EmptyGlassCard(
                        symbol: "list.bullet.rectangle",
                        title: L("Nothing recorded yet"),
                        text: L("Uses by approved callers and background reads will appear here.")
                    )
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry)
                            if index < entries.count - 1 {
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
        .onAppear {
            entries = AccessLogBuilder.entries(
                serviceGrants: (try? serviceGrantStore.grants()) ?? [],
                auditEvents: (try? serviceGrantStore.auditEvents()) ?? []
            )
        }
    }

    private func row(_ entry: AccessLogEntry) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(entry.who) · \(label(for: entry.credentialId))").lineLimit(1).truncationMode(.middle)
                Text(entry.detail).font(.caption.monospaced()).foregroundColor(.secondary)
            }
            Spacer()
            tag(entry.kind)
            Text(relative(entry.date)).font(.caption).foregroundColor(.secondary)
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
            Text(L("Read without approval")).font(.caption2.weight(.semibold)).foregroundColor(.orange)
        case .approvalRequired:
            Text(L("Asked for approval")).font(.caption2.weight(.semibold)).foregroundColor(.secondary)
        }
    }

    private func label(for id: String) -> String {
        credentials.first { $0.id == id }?.credential.label ?? id
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
