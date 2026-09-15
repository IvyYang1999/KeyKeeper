import SwiftUI
import KeyKeeperCore

/// Keep the list mounted even on compact windows, so returning does not lose its scroll position.
struct ActivityDetailLayout<Content: View, Detail: View>: View {
    let hasSelection: Bool
    var selectionID: String? = nil
    let onBack: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        GeometryReader { geometry in
            let split = ActivityDetailLayoutPolicy.isSplit(width: geometry.size.width)
            let compactDetail = hasSelection && !split
            let detailWidth: CGFloat = split ? 380 : geometry.size.width
            content()
                .frame(width: hasSelection && split ? geometry.size.width - detailWidth - 1 : geometry.size.width)
                .opacity(compactDetail ? 0 : 1)
                .allowsHitTesting(!compactDetail)
                .accessibilityHidden(compactDetail)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    if hasSelection {
                        HStack(spacing: 0) {
                            if split { Divider() }
                            VStack(alignment: .leading, spacing: 0) {
                                Button(action: onBack) {
                                    Label(L("Back to list"), systemImage: "chevron.left")
                                }
                                .buttonStyle(.plain).foregroundColor(.accentColor)
                                .keyboardShortcut(.escape, modifiers: [])
                                .padding(20)
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 18) { detail() }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 20).padding(.bottom, 24)
                                }
                                .id(selectionID)
                            }
                            .frame(width: detailWidth)
                        }
                    }
                }
        }
    }
}

struct ActivityRecordButton<Content: View>: View {
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content()
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ActivityFact: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: label).font(.caption).foregroundColor(.secondary)
            Text(verbatim: value).font(.callout).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Only what the caller actually wrote. An empty reason is not a fact worth a row; the
/// authorization window already told the person, in orange, that none was given.
struct ActivityRequestFacts: View {
    let reason: String?
    let command: String?
    private var hasReason: Bool { !(reason ?? "").isEmpty }
    private var hasCommand: Bool { !(command ?? "").isEmpty }
    var body: some View {
        if hasReason { ActivityFact(label: L("Reason given by the caller"), value: ActivityDetailCopy.text(reason)) }
        if hasCommand { ActivityFact(label: L("Command"), value: ActivityDetailCopy.command(command)) }
        if hasReason || hasCommand {
            Text(L("Written by the caller itself, not verified. Commands are shortened and common secrets hidden."))
                .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AccessHistoryTag: View {
    let kind: AccessLogEntry.Kind
    static func text(_ kind: AccessLogEntry.Kind) -> String {
        switch kind {
        case .approvedUse: return L("Read with approval")
        case .readWithoutApproval: return L("Read without asking")
        case .approvalRequired: return L("Asked for approval")
        }
    }
    var body: some View {
        Text(Self.text(kind)).font(.caption.weight(.semibold))
            .foregroundColor(kind == .approvedUse ? .green : kind == .readWithoutApproval ? .orange : .secondary)
    }
}

struct AccessHistoryDetail: View {
    let group: AccessLogGroup
    let currentStatus: AccessLogApprovalStatus
    let label: String
    var openCredential: (() -> Void)?
    /// Present when this request can still be approved as a standing permission.
    var approve: (() -> Void)?

    var body: some View {
        Text(L("Access details")).font(.title2.weight(.semibold))
        ActivityFact(label: L("Caller"), value: ActivityDetailCopy.text(group.who))
        ActivityFact(label: L("Credential"), value: ActivityDetailCopy.credential(label: label, id: group.credentialId))
        if let openCredential { Button(L("View credential"), action: openCredential) }
        ActivityFact(label: group.kind == .approvedUse ? L("Scope of the recorded approval") : L("Recorded fields"),
            value: group.kind == .approvedUse && group.approvalFields == nil ? L("every secret field") : ActivityDetailCopy.text(group.detail))
        ActivityFact(label: L("What happened then"), value: AccessHistoryTag.text(group.kind))
        ActivityFact(label: L("Permission now"), value: currentStatus == .approved ? L("Currently approved") : currentStatus == .unavailable ? L("Approval status unavailable") : L("No matching current approval"))
        if let approve, currentStatus == .notApproved {
            Button(L("Approve now"), action: approve).controlSize(.small)
        }
        ActivityFact(label: L("Latest recorded time"), value: ActivityDetailCopy.absolute(group.latest))
        ActivityRequestFacts(reason: group.reason, command: group.command)
        // One record is the summary above; a list only earns its place with two or more.
        if group.entries.count > 1 {
            Divider()
            Text(L("\(group.entries.count) records")).font(.headline)
            ForEach(group.entries) { event in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(ActivityDetailCopy.absolute(event.date)).font(.callout)
                        Spacer()
                        AccessHistoryTag(kind: event.kind)
                    }
                    if event.reason != group.reason || event.command != group.command {
                        ActivityRequestFacts(reason: event.reason, command: event.command)
                    }
                }
            }
        }
    }
}

struct MetadataHistoryDetail: View {
    let record: MetadataChangeRecord
    var openCredential: (() -> Void)?
    var body: some View {
        Text(L("Change details")).font(.title2.weight(.semibold))
        ActivityFact(label: L("Caller"), value: ActivityDetailCopy.text(record.caller))
        ActivityFact(label: L("Credential"), value: ActivityDetailCopy.credential(label: ActivityDetailCopy.text(record.label), id: record.groupId))
        if let openCredential { Button(L("View credential"), action: openCredential) }
        ActivityFact(label: L("Recorded time"), value: ActivityDetailCopy.absolute(record.timestamp))
        Divider()
        ForEach(Array(record.changes.enumerated()), id: \.offset) { _, change in
            Text(verbatim: ActivityDetailCopy.text(MetadataEditCopy.text(change)))
                .font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Text(L("Only the recorded changes are shown; note contents and some previous values were not kept."))
            .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
