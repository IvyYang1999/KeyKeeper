import AppKit

/// AppDelegate already owns every window. A SwiftUI Settings Scene would create
/// a second, independent settings window beside the console.
@main
struct KeyKeeperApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // NSApplication.delegate is weak; keep this owner for the entire run loop.
        withExtendedLifetime(delegate) { application.run() }
    }
}
