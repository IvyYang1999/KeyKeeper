import SwiftUI

/// Rows of the General group. The production rows can also render offline with a synthetic driver.
struct UpdatesSettingsRows: View {
    @ObservedObject var updateController: UpdateController
    var version = Self.installedVersion

    /// "0.3.6 (8e51f563afeb)", or just the revision for a development build without a bundle version.
    static var installedVersion: String {
        let revision = BuildVersion.identifier.replacingOccurrences(of: "keykeeper ", with: "")
        if let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !short.isEmpty {
            return "\(short) (\(revision))"
        }
        return revision
    }

    var body: some View {
        SettingsRow(title: L("Download updates in the background"), detail: description) {
            SettingsSwitch(label: L("Download updates in the background"), isOn: Binding(
                get: { updateController.automaticallyDownloadsUpdates },
                set: { updateController.setAutomaticallyDownloadsUpdates($0) }
            ))
            .disabled(!updateController.isAvailable)
        }
        SettingsDivider()
        SettingsRow(title: L("Version"), detail: version) {
            Button(L("Check for Updates…")) { updateController.checkForUpdates() }
                .disabled(!updateController.canCheckForUpdates)
        }
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
