import SwiftUI
import KeyKeeperCore

private enum ActivitySelection {
    case access(AccessLogGroup), change(MetadataChangeRecord)
    var id: String {
        switch self { case .access(let row): return row.id; case .change(let row): return row.id }
    }
}

@MainActor struct AccessLogPage: View {
    let credentials: [(id: String, credential: Credential)]
    var onOpenCredential: ((String) -> Void)?
    @StateObject private var access: AccessLogApprovalState
    @State private var tab = ActivityTab.defaultTab
    @State private var selected: ActivitySelection?
    @State private var edits: [MetadataChangeRecord] = []
    @State private var editsError: String?
    private let loadEdits: () throws -> [MetadataChangeRecord]
    /// Layout tests and renders open the page with the first record already selected.
    private let selectsFirstRecord: Bool

    init(credentials: [(id: String, credential: Credential)], access: AccessLogApprovalState? = nil,
         loadEdits: @escaping () throws -> [MetadataChangeRecord] = { try MetadataChangeLog.default.records() },
         onOpenCredential: ((String) -> Void)? = nil, selectsFirstRecord: Bool = false) {
        self.credentials = credentials
        self._access = StateObject(wrappedValue: access ?? AccessLogApprovalState())
        self.loadEdits = loadEdits
        self.onOpenCredential = onOpenCredential
        self.selectsFirstRecord = selectsFirstRecord
    }

    var body: some View {
        ActivityDetailLayout(hasSelection: selected != nil, selectionID: selected?.id, onBack: { selected = nil }) {
            VStack(alignment: .leading, spacing: 16) {
                // The record type sits beside the title it changes, not floating above it.
                HStack(alignment: .top, spacing: 16) {
                    MainPageHeader(title: tab.title, subtitle: tab == .access
                        ? L("Who used which key, and when. Select a row for details.")
                        : L("Names and notes changed by callers. Not key reads."))
                    Spacer(minLength: 0)
                    Picker(L("Record type"), selection: $tab) {
                        ForEach(ActivityTab.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28).padding(.top, 12)
                .frame(maxWidth: 776, alignment: .leading)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if tab == .access { accessList } else { changesList }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 24)
                    .frame(maxWidth: 776, alignment: .leading)
                }
                // Different record types start at the top. Detail navigation leaves this
                // same scroll view mounted, preserving its position when going back.
                .id(tab)
            }
        } detail: {
            switch selected {
            case .access(let snapshot):
                let group = access.groups.first { $0.id == snapshot.id } ?? snapshot
                AccessHistoryDetail(group: group, currentStatus: access.status(for: group), label: label(group.credentialId),
                    openCredential: openAction(group.credentialId), approve: approveAction(group))
            case .change(let record):
                MetadataHistoryDetail(record: record, openCredential: openAction(record.groupId))
            case nil: EmptyView()
            }
        }
        .onAppear {
            load()
            if selectsFirstRecord, let first = access.groups.first { selected = .access(first) }
        }
        .onChange(of: tab) { _, _ in selected = nil; load() }
        .background(AccessLogRefreshObserver(onRefresh: load, canAutoRefresh: {
            tab == .access ? access.errorMessage == nil : editsError == nil
        }))
    }

    @ViewBuilder private var accessList: some View {
        if access.permissive && access.groups.contains(where: { $0.kind == .readWithoutApproval }) {
            PermissiveModeBanner(caption: L("Callers below will each be asked once, the next time they read."), onEnforce: load)
        }
        if let error = access.errorMessage {
            Text(error).font(.callout).foregroundColor(.orange)
            Button(L("Refresh"), action: load)
        }
        if access.groups.isEmpty && access.errorMessage == nil {
            EmptyGlassCard(symbol: "list.bullet.rectangle", title: L("Nothing recorded yet"),
                text: L("Uses by approved callers and background reads will appear here."))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(access.groups) { group in
                    let status = access.status(for: group)
                    HStack(spacing: 4) {
                        ActivityRecordButton(selected: selected?.id == group.id, action: { selected = .access(group) }) {
                            ActivityLine(caller: group.who, keyLabel: label(group.credentialId),
                                         keyAvatar: avatar(group.credentialId),
                                         result: AccessHistoryTag.text(group.kind),
                                         tone: ActivityLine.tone(group.kind, status: status),
                                         time: ActivityDetailCopy.relative(group.latest), count: group.count)
                                .help(group.kind == .approvalRequired && status == .approved ? L("Currently approved") : "")
                        }
                        // Same width on every row when any row has the button, so the columns line up.
                        if access.groups.contains(where: { approveAction($0) != nil }) {
                            Color.clear.frame(width: 96, height: 1)
                                .overlay(alignment: .trailing) { approveButton(group).fixedSize() }
                                .padding(.trailing, 10)
                        }
                    }
                    .id(group.id)
                    if group.id != access.groups.last?.id { GlassSeparator() }
                }
            }
            .scrollTargetLayout().glassCard()
        }
    }

    @ViewBuilder private var changesList: some View {
        if let editsError {
            Text(editsError).font(.callout).foregroundColor(.orange)
            Button(L("Refresh"), action: load)
        }
        if edits.isEmpty && editsError == nil {
            EmptyGlassCard(symbol: "pencil", title: L("No changes recorded"), text: L("Caller changes to names and notes will appear here."))
        } else {
            LazyVStack(spacing: 0) {
                ForEach(edits) { record in
                    ActivityRecordButton(selected: selected?.id == record.id, action: { selected = .change(record) }) {
                        HStack(spacing: 14) {
                            CallerMark(callerId: CallerAppIcon.lookupId(forName: record.caller), size: 20)
                            Text(verbatim: ActivityDetailCopy.text(MetadataEditCopy.headline(record)))
                                .lineLimit(1)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            Text(ActivityDetailCopy.relative(record.timestamp)).foregroundStyle(.secondary)
                                .frame(width: 96, alignment: .trailing)
                        }
                        .font(.callout)
                    }
                    .id(record.id)
                    if record.id != edits.last?.id { GlassSeparator() }
                }
            }
            .scrollTargetLayout().glassCard()
        }
    }

    @ViewBuilder private func approveButton(_ group: AccessLogGroup) -> some View {
        if let approve = approveAction(group) {
            Button(L("Approve now"), action: approve).font(.caption).controlSize(.small)
        }
    }

    private func approveAction(_ group: AccessLogGroup) -> (() -> Void)? {
        guard group.kind == .approvalRequired, access.status(for: group) == .notApproved,
              let standing = standingRequest(group) else { return nil }
        return {
            access.refresh()
            guard access.status(for: group) == .notApproved else { return }
            StandingApprovalRequester.shared.handler?(standing)
        }
    }

    private func load() {
        if tab == .access { access.refresh() }
        else {
            do { edits = try loadEdits().sorted { $0.timestamp > $1.timestamp }; editsError = nil }
            catch { editsError = L("Change history could not be read. No data was changed.") }
        }
    }
    private func credential(_ id: String) -> Credential? {
        credentials.first { $0.id == id || $0.credential.aliases?.contains(id) == true }?.credential
    }
    private func label(_ id: String) -> String { credential(id)?.label ?? id }
    private func avatar(_ id: String) -> KeyAvatar {
        credential(id).map { KeyAvatar(credential: $0, size: 20) } ?? KeyAvatar(label: id, size: 20)
    }
    private func openAction(_ id: String) -> (() -> Void)? {
        guard credential(id) != nil, let onOpenCredential else { return nil }
        return { onOpenCredential(id) }
    }
    private func standingRequest(_ group: AccessLogGroup) -> StandingApprovalRequest? {
        let fields = credential(group.credentialId).map { $0.fields.filter(\.value.secret).map(\.key).sorted() } ?? [group.detail]
        return StandingApprovalRequest(group: group, credentialLabel: label(group.credentialId), fieldNames: fields)
    }
}
