import AppKit

/// Right-click menu on the menu bar icon. The entry list is pure so it can be tested;
/// `build` turns it into an NSMenu wired to the delegate's selectors.
enum StatusMenuBuilder {
    enum Entry: Equatable {
        case open
        case checkForUpdates
        case launchAtLogin(enabled: Bool, available: Bool)
        case settings
        case separator
        case quit
    }

    static func entries(launchAtLogin: Bool, launchAtLoginAvailable: Bool) -> [Entry] {
        [
            .open,
            .checkForUpdates,
            .separator,
            .launchAtLogin(enabled: launchAtLogin, available: launchAtLoginAvailable),
            .settings,
            .separator,
            .quit,
        ]
    }

    struct Actions {
        let open: Selector
        let checkForUpdates: Selector
        let launchAtLogin: Selector
        let settings: Selector
        let quit: Selector
    }

    static func build(
        launchAtLogin: Bool,
        launchAtLoginAvailable: Bool,
        target: AnyObject,
        actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()
        for entry in entries(launchAtLogin: launchAtLogin, launchAtLoginAvailable: launchAtLoginAvailable) {
            switch entry {
            case .open:
                menu.addItem(item("Open KeyKeeper", actions.open, target))
            case .checkForUpdates:
                menu.addItem(item("Check for Updates…", actions.checkForUpdates, target))
            case .launchAtLogin(let enabled, let available):
                let launch = item("Launch at Login", actions.launchAtLogin, target)
                launch.state = enabled ? .on : .off
                launch.isEnabled = available
                if !available {
                    launch.toolTip = "Available when KeyKeeper runs from an .app bundle."
                }
                menu.addItem(launch)
            case .settings:
                menu.addItem(item("Settings\u{2026}", actions.settings, target))
            case .separator:
                menu.addItem(.separator())
            case .quit:
                menu.addItem(item("Quit KeyKeeper", actions.quit, target))
            }
        }
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ target: AnyObject) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        return item
    }
}
