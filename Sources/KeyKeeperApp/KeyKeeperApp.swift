import SwiftUI

@main
struct KeyKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        // Only reachable while the main window makes KeyKeeper a regular app.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("Settings…")) { appDelegate.showMainWindow(section: .settings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button(L("New key group")) {
                    MainWindowRouter.shared.isAdding = true
                    appDelegate.showMainWindow(section: .keys)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}
