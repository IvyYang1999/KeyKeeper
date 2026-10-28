import SwiftUI

/// The production card can also render offline with a synthetic update driver.
struct UpdatesSettingsCard: View {
    @ObservedObject var updateController: UpdateController

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            SectionLabel(text: L("Updates"))
            Toggle(isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.setAutomaticallyDownloadsUpdates($0) }
            )) {
                Text(L("Download updates in the background"))
                    .font(.callout)
            }
            .disabled(!updateController.isAvailable)

            Text(description)
                .font(.caption2)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(L("Check for Updates…")) { updateController.checkForUpdates() }
                .font(.caption)
                .disabled(!updateController.canCheckForUpdates)
        }
        .dsCard(padding: DS.Spacing.md)
    }

    private var description: String {
        guard updateController.isAvailable else {
            return L("Updates are unavailable in this development build.")
        }
        return updateController.automaticallyDownloadsUpdates
            ? L("While KeyKeeper is running, it checks every 6 hours by default. Signed updates download in the background and install when you quit. If you keep the app open, it reminds you after a day.")
            : L("While KeyKeeper is running, it checks every 6 hours by default and asks before downloading a signed update.")
    }
}
