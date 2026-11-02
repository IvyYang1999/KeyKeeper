import SwiftUI

/// Shared by the menu and main-window lists. Failure must not look like an empty vault.
struct CredentialListFailureNotice: View {
    let reason: String
    let hasLastKnownRows: Bool
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("Credential access is paused"), systemImage: "lock.trianglebadge.exclamationmark")
                .font(.callout.weight(.semibold)).foregroundColor(.orange)
            Text(AppL10n.text(reason)).font(.caption).foregroundColor(.secondary)
            if hasLastKnownRows {
                Text(L("The last loaded list is shown below. Reading values and making changes stay blocked until verification succeeds."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Button(L("Try again"), action: retry).controlSize(.small)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(.card, radius: 12)
    }
}
