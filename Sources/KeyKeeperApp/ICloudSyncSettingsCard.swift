import SwiftUI

/// Pure presentation. Services, persistence and authorization belong to the App model.
struct ICloudSyncSettingsCard: View {
    let state: ICloudSyncPresentation
    let action: (ICloudSyncAction) -> Void
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case enable, migrate, review(ICloudSyncPresentation.ConflictReview)
        var id: String {
            switch self {
            case .enable: "enable"
            case .migrate: "migrate"
            case .review(let review): review.id.uuidString
            }
        }
    }

    @State private var showDetails = false

    /// 【曾经的 bug】2026-11-07 yyt：「iCloud 同步部分也很糟糕，两个按钮居然是那样的排布」——「重试」「关闭同步」
    /// 竖着叠在左边、宽度不一；「48 条记录缺少 96 个值」这种诊断和状态一样醒目。Now one status line with a dot,
    /// the reason under it, the buttons side by side on the right, and the diagnostics folded away.
    var body: some View {
        SettingsGroup(title: L("iCloud sync")) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Spacing.lg) {
                    summary.frame(maxWidth: .infinity, alignment: .leading)
                    actions.fixedSize()
                }
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    summary
                    actions.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if !detailLines.isEmpty {
                SettingsDivider()
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ForEach(detailLines, id: \.self) { Text($0) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Spacing.xs)
                    .accessibilityElement(children: .combine)
                } label: {
                    Text(L("Details")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $sheet) { item in
            switch item {
            case .enable: ICloudSyncConfirmation(kind: .enable, action: action)
            case .migrate: ICloudSyncConfirmation(kind: .migrate, action: action)
            case .review(let review):
                ICloudSyncConflictSheet(review: review, currentReviewID: state.review?.id, action: action)
            }
        }
        .onChange(of: state.review?.id) { _, id in
            if case .review(let original) = sheet, original.id != id { sheet = nil }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                if state.phase == .syncing {
                    ProgressView().controlSize(.mini)
                } else {
                    StatusDot(tone: tone)
                }
                Text(status).fontWeight(.medium)
            }
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let retry = Self.retryText(state) {
                Text(retry)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let lastSuccess = state.lastSuccess {
                Text(L("Last synced: \(lastSuccess.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(AppL10n.locale)))"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The pause is not the end: say when KeyKeeper tries again, so nobody has to click to find out.
    /// An unconfirmed upload is only re-checked automatically, so it says "check", not "try".
    static func retryText(_ state: ICloudSyncPresentation) -> String? {
        guard let next = state.nextRetry, state.retriesAutomatically else { return nil }
        let time = next.formatted(.dateTime.hour().minute().locale(AppL10n.locale))
        return state.issue == .pendingUpload
            ? L("Will check again automatically at \(time).")
            : L("Will try again automatically at \(time).")
    }

    /// Why it is in this state; when nothing is wrong, what sync does.
    private var reason: String {
        if let issue = state.issue { return Self.issueText(issue) }
        return L("Sync keys and notes across your Macs. Each Mac approves its own callers.")
    }

    private var tone: StatusDot.Tone {
        switch state.phase {
        case .off: .off
        case .ready, .syncing: .good
        case .paused, .unavailable, .conflict, .migrationRequired: .attention
        }
    }

    /// Diagnostics and reassurance: true, but not what the person came here to read.
    private var detailLines: [String] {
        var lines: [String] = []
        if let records = state.missingCredentialCount, let fields = state.missingFieldCount,
           records > 0, fields > 0 {
            lines.append(L("At last sync check: \(records) records have \(fields) missing values."))
            lines.append(L("Records are preserved; available values can sync. Missing values do not replace saved values on another Mac."))
        }
        if state.enabled {
            lines.append(L("Turning sync off keeps your data on this Mac and in iCloud."))
        }
        return lines
    }

    /// Side by side, the way out on the left and the thing to do on the right. It is the blue
    /// button only when something waits on the person.
    @ViewBuilder private var actions: some View {
        HStack(spacing: DS.Spacing.sm) {
            if state.enabled {
                Button(L("Turn off sync")) { action(.disable) }
                    .help(L("Turning sync off keeps your data on this Mac and in iCloud."))
            }
            switch state.phase {
            case .off:
                Button(L("Enable iCloud Sync…")) { sheet = .enable }
            case .migrationRequired:
                Button(L("Move to protected storage…")) { sheet = .migrate }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.issue == .unsupportedMigration)
            case .conflict:
                if let review = state.review {
                    Button(L("Review \(review.rows.count) conflicts…")) { sheet = .review(review) }
                        .buttonStyle(.borderedProminent)
                }
            case .ready:
                Button(L("Sync now")) { action(.syncNow) }
            case .paused, .unavailable:
                if state.issue == .pendingUpload {
                    Button(L("Check and retry sync")) { action(.retryPendingUpload) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(L("Retry")) { action(.retry) }
                        .buttonStyle(.borderedProminent)
                }
            case .syncing: EmptyView()
            }
        }
    }

    private var status: String {
        switch state.phase {
        case .off: L("Off")
        case .ready: L("Sync is on")
        case .syncing: L("Syncing…")
        case .paused: L("Sync paused")
        case .conflict: L("Choose which versions to keep")
        case .unavailable: L("Sync unavailable")
        case .migrationRequired: L("Prepare this Mac first")
        }
    }

    static func issueText(_ issue: ICloudSyncPresentation.Issue) -> String {
        switch issue {
        case .identityUnavailable: L("This version cannot use iCloud sync. Install a version with iCloud support.")
        case .accountChanged: L("Your iCloud account changed or is unavailable. Sync is paused to keep accounts separate.")
        case .incompleteVault: L("Credential data could not be verified. Existing data was kept. Restore storage access before retrying.")
        case .storageUnavailable: L("Protected storage is unavailable. Existing data has been kept; retry after access is restored.")
        case .networkUnavailable: L("iCloud could not be reached. Your local keys are still available.")
        case .pendingUpload: L("The last upload could not be confirmed. Check its result before trying it again.")
        case .stale: L("A version changed while you were reviewing it. Review the latest versions before continuing.")
        case .unsupportedMigration: L("This Mac has data that cannot be moved automatically yet. Originals remain unchanged.")
        case .unsupportedSnapshotVersion: L("This version of KeyKeeper cannot read the sync data. Update KeyKeeper on this Mac before retrying.")
        }
    }
}

struct ICloudSyncConfirmation: View {
    enum Kind { case enable, migrate }
    let kind: Kind
    let action: (ICloudSyncAction) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.lg) {
            Text(kind == .enable ? L("Enable iCloud sync?") : L("Move this Mac’s data?"))
                .font(.headline)
            Text(kind == .enable
                 ? L("Keys and notes will be encrypted and uploaded to your iCloud account. Your other Macs can receive them after you enable sync there.")
                 : L("Move local data into KeyKeeper’s new protected store. Originals stay available for recovery. Sync stays off until you enable it."))
                .font(.callout)
            Text(kind == .enable
                 ? L("Caller approvals stay on each Mac. Approve callers separately on your other Macs.")
                 : L("Caller approvals do not travel between Macs. Callers will need approval again after this move."))
                .font(.caption).foregroundStyle(.secondary)
            if kind == .enable {
                Text(L("Update KeyKeeper on all your Macs before syncing records with missing values. Older versions cannot read these records."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Cancel"), role: .cancel) { dismiss() }
                Spacer(minLength: DS.Spacing.sm)
                Button(kind == .enable ? L("Enable sync") : L("Move data")) {
                    action(kind == .enable ? .enable : .migrate)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DS.Spacing.xl)
        .frame(minWidth: 280, idealWidth: 420, maxWidth: 600)
    }
}

struct ICloudSyncConflictSheet: View {
    let review: ICloudSyncPresentation.ConflictReview
    let currentReviewID: UUID?
    let action: (ICloudSyncAction) -> Void
    @State private var selection: ICloudSyncReviewSelection
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    init(review: ICloudSyncPresentation.ConflictReview, currentReviewID: UUID?,
         action: @escaping (ICloudSyncAction) -> Void) {
        self.review = review; self.currentReviewID = currentReviewID; self.action = action
        _selection = State(initialValue: .init(reviewID: review.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.md) {
            Text(L("Choose which versions to keep")).font(.headline)
            Text(L("Both versions have been kept while sync is paused. Values stay hidden."))
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.md) {
                    ForEach(review.rows) { row in
                        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                            Text(row.label.isEmpty ? row.id : row.label)
                                .font(.callout.weight(.medium)).textSelection(.enabled)
                            version(L("This Mac"), exists: row.localExists, updated: row.localUpdated)
                            version("iCloud", exists: row.remoteExists, updated: row.remoteUpdated)
                            Picker(L("Keep version"), selection: Binding<ICloudSyncChoice?>(
                                get: { selection.choices[row.id] },
                                set: { value in
                                    if let value { selection.select(value, for: row.id, review: review) }
                                    confirming = false
                                })) {
                                Text(L("Choose a version…")).tag(Optional<ICloudSyncChoice>.none)
                                Text(L("Keep this Mac’s version")).tag(Optional(ICloudSyncChoice.local))
                                    .disabled(!row.canChooseLocal)
                                Text(L("Use iCloud’s version")).tag(Optional(ICloudSyncChoice.remote))
                                    .disabled(!row.canChooseRemote)
                            }
                            .labelsHidden().pickerStyle(.menu)
                            .disabled(currentReviewID != review.id)
                            if !row.canChooseLocal || !row.canChooseRemote {
                                Text(L("A version with missing values cannot replace available values on the other Mac."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .dsCard(padding: DS.Spacing.md)
                    }
                }
            }
            .frame(maxHeight: 340)
            if currentReviewID != review.id {
                Text(ICloudSyncSettingsCard.issueText(.stale)).font(.caption).foregroundStyle(.secondary)
            } else if confirming {
                Text(L("These choices replace the other versions on this Mac and in iCloud. Choosing a deleted version removes that key. Changed keys need caller approval again."))
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(L("Not now"), role: .cancel) { dismiss() }
                Spacer(minLength: DS.Spacing.sm)
                Button(confirming ? L("Confirm choices") : L("Apply choices…")) {
                    guard let resolved = selection.action(for: review, currentReviewID: currentReviewID) else { return }
                    if confirming { action(resolved); dismiss() } else { confirming = true }
                }
                .disabled(selection.action(for: review, currentReviewID: currentReviewID) == nil)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(minWidth: 280, idealWidth: 440, maxWidth: 600)
        .onChange(of: currentReviewID) { _, id in
            selection.updateReview(id ?? UUID())
            confirming = false
        }
    }

    private func version(_ name: String, exists: Bool, updated: String?) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(exists ? L("\(name): saved") : L("\(name): deleted")).font(.caption)
            if let updated, exists, !updated.isEmpty {
                Text(updated).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
