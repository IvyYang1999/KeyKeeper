import SwiftUI
import KeyKeeperCore

@MainActor struct ApprovedCallersPage: View {
    let credentials: [(id: String, credential: Credential)]
    var onOpenCredential: ((String) -> Void)?
    @StateObject private var state: PermissionPageState
    @State private var selected: Approval?
    @State private var pendingRevoke: Approval?

    init(credentials: [(id: String, credential: Credential)], state: PermissionPageState? = nil,
         onOpenCredential: ((String) -> Void)? = nil) {
        self.credentials = credentials
        self.onOpenCredential = onOpenCredential
        self._state = StateObject(wrappedValue: state ?? PermissionPageState())
    }

    var body: some View {
        ActivityDetailLayout(hasSelection: selected != nil, selectionID: selected?.id, onBack: { selected = nil }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MainPageHeader(title: L("Usage permissions"), subtitle: L("Who has permission, not who is running right now. Select an approval to see its exact scope or revoke it."))
                    if state.permissive { PermissiveModeBanner(onEnforce: state.refresh) }
                    if let error = state.errorMessage {
                        Text(error).font(.callout).foregroundColor(.orange)
                        Button(L("Refresh"), action: state.refresh)
                    }
                    if state.available && PermissionGroup.build(state.approvals).isEmpty {
                        EmptyGlassCard(symbol: "checkmark.shield", title: L("No one is approved yet"),
                            text: L("The first time a script or agent asks for a key, KeyKeeper asks you once. What you approve shows up here."))
                    }
                    ForEach(PermissionGroup.build(state.approvals)) { group in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(verbatim: group.who).font(.headline)
                            VStack(spacing: 0) {
                                ForEach(group.approvals) { approval in
                                    ActivityRecordButton(selected: selected?.id == approval.id, action: { selected = approval }) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(verbatim: label(approval.target.credentialId ?? "")).font(.callout.weight(.semibold))
                                            Text(AccessEntryBuilder.scopeLabel(approval, now: state.now)).font(.caption).foregroundColor(.secondary)
                                            Text(L("Approval reference: \(approval.id.prefix(8))")).font(.caption2).foregroundColor(.secondary)
                                            Text(permissionStatus(approval)).font(.caption)
                                                .foregroundColor(state.available && state.isActive(approval) ? .green : .secondary)
                                        }
                                    }
                                    if approval.id != group.approvals.last?.id { GlassSeparator() }
                                }
                            }.glassCard()
                        }
                    }
                }
                .padding(.horizontal, 28).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 720, alignment: .leading)
            }
        } detail: {
            if let selected {
                let current = state.approvals.first { $0.id == selected.id }
                let displayed = current ?? selected
                Text(L("Permission details")).font(.title2.weight(.semibold))
                ActivityFact(label: L("Caller"), value: AccessEntryBuilder.who(displayed))
                ActivityFact(label: L("Identity"), value: AccessEntryBuilder.details(displayed, now: state.now).first?.value ?? L("Not recorded"))
                ActivityFact(label: L("Credential"), value: label(displayed.target.credentialId ?? "") + " · " + (displayed.target.credentialId ?? ""))
                if let id = displayed.target.credentialId, hasCredential(id), let onOpenCredential {
                    Button(L("View credential")) { onOpenCredential(id) }
                }
                ActivityFact(label: L("Permission now"), value: !state.available ? L("Approval status unavailable") : current == nil ? L("Revoked or removed") : permissionStatus(displayed))
                ActivityFact(label: L("Authorization scope"), value: scope(displayed))
                ActivityFact(label: L("Duration"), value: AccessEntryBuilder.scopeLabel(displayed, now: state.now))
                if let expiry = expiry(displayed) {
                    ActivityFact(label: L("Valid no later than"), value: ActivityDetailCopy.absolute(expiry))
                }
                ActivityFact(label: L("Approved"), value: ActivityDetailCopy.absolute(displayed.createdAt))
                ActivityFact(label: L("Last used"), value: displayed.lastUsedAt.map(ActivityDetailCopy.absolute) ?? L("Not recorded"))
                ActivityFact(label: L("Approval reference"), value: displayed.id)
                ActivityRequestFacts(reason: displayed.reason, command: displayed.command)
                if let error = state.errorMessage { Text(error).font(.caption).foregroundColor(.orange) }
                if state.available, current != nil {
                    Button(L("Revoke this approval…"), role: .destructive) { pendingRevoke = displayed }
                }
            }
        }
        .onAppear(perform: state.refresh)
        .background(AccessLogRefreshObserver(onRefresh: state.refresh, canAutoRefresh: { state.errorMessage == nil }))
        .confirmationDialog(L("Revoke this approval?"), isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }), titleVisibility: .visible) {
            if let pendingRevoke {
                Button(L("Revoke"), role: .destructive) { state.revoke(pendingRevoke); self.pendingRevoke = nil }
            }
            Button(L("Cancel"), role: .cancel) { pendingRevoke = nil }
        } message: {
            if let pendingRevoke {
                Text(L("\(AccessEntryBuilder.who(pendingRevoke)) · \(label(pendingRevoke.target.credentialId ?? "")) · \(pendingRevoke.id.prefix(8)). Only this approval will be removed. It does not erase copies already received or revoke other approvals."))
            }
        }
    }

    private func permissionStatus(_ approval: Approval) -> String {
        !state.available ? L("Approval status unavailable") : state.isActive(approval) ? L("Currently approved") : L("No longer applies")
    }
    private func hasCredential(_ id: String) -> Bool { credentials.contains { $0.id == id || $0.credential.aliases?.contains(id) == true } }
    private func label(_ id: String) -> String {
        credentials.first { $0.id == id || $0.credential.aliases?.contains(id) == true }?.credential.label ?? id
    }
    private func scope(_ approval: Approval) -> String {
        guard case .credential(_, let fields) = approval.target else { return L("Not recorded") }
        return fields.map { $0.joined(separator: ", ") } ?? L("Every secret field, including fields added later.")
    }
    private func expiry(_ approval: Approval) -> Date? {
        switch approval.duration {
        case .timed(let date): return date
        case .once: return approval.createdAt.addingTimeInterval(Approval.onceWindow)
        case .terminalSession: return approval.createdAt.addingTimeInterval(Approval.terminalSessionMaxAge)
        case .process: return approval.createdAt.addingTimeInterval(Approval.processMaxAge)
        case .always: return nil
        }
    }
}
