import SwiftUI
import KeyKeeperCore

enum BrowserImportProposalDisplay {
    static func recoverable(_ snapshot: BrowserImportProposalSnapshot?, now: Date = Date())
        -> BrowserImportProposalSnapshot? {
        guard let snapshot, snapshot.state == .pasteReceived,
              snapshot.deadline.map({ $0 > now }) == true else { return nil }
        return snapshot
    }

    static func badgeCount(_ snapshot: BrowserImportProposalSnapshot?, now: Date = Date()) -> Int {
        recoverable(snapshot, now: now) == nil ? 0 : 1
    }
}

/// A recovered paste is not a second approval. It is a durable way back to the original prompt.
/// Only public proposal metadata reaches this view.
struct BrowserImportProposalNotice: View {
    let proposal: BrowserImportProposalSnapshot
    let onReview: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "safari.fill")
                    .foregroundColor(.orange)
                    .frame(width: 26, height: 26)
                    .surface(.raised, radius: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Finish saving this browser paste"))
                        .font(.callout.weight(.semibold))
                    Text(verbatim: proposal.credentialId + " · " + proposal.fieldName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(L("The pasted value stays hidden in Keychain until you review or cancel it."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 8) {
                if let deadline = proposal.deadline {
                    Label { Text(deadline, style: .timer).monospacedDigit() } icon: {
                        Image(systemName: "clock")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                Spacer()
                Button(L("Cancel"), action: onCancel)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser-import-cancel")
                Button(L("Review…"), action: onReview)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("browser-import-review")
            }
        }
        .padding(12)
        .surface(.attention, radius: 14)
        .accessibilityIdentifier("browser-import-recovery")
    }
}
