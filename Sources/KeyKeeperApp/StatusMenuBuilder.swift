import AppKit

/// Right-click menu on the menu bar icon. The entry list is pure so it can be tested;
/// `build` turns it into an NSMenu wired to the delegate's selectors.
enum StatusMenuBuilder {
    enum Entry: Equatable {
        case open
        case lock
        case unlock
        case createVault
        case launchAtLogin(enabled: Bool, available: Bool)
        case settings
        case separator
        case quit
    }

    static func entries(state: SessionBannerState, launchAtLogin: Bool, launchAtLoginAvailable: Bool) -> [Entry] {
        var entries: [Entry] = [.open, .separator]
        switch state {
        case .unlocked: entries.append(.lock)
        case .locked: entries.append(.unlock)
        case .needsVault: entries.append(.createVault)
        }
        entries.append(.launchAtLogin(enabled: launchAtLogin, available: launchAtLoginAvailable))
        entries.append(.settings)
        entries.append(.separator)
        entries.append(.quit)
        return entries
    }

    struct Actions {
        let open: Selector
        let lock: Selector
        let unlock: Selector
        let launchAtLogin: Selector
        let settings: Selector
        let quit: Selector
    }

    static func build(
        state: SessionBannerState,
        launchAtLogin: Bool,
        launchAtLoginAvailable: Bool,
        target: AnyObject,
        actions: Actions
    ) -> NSMenu {
        let menu = NSMenu()
        for entry in entries(state: state, launchAtLogin: launchAtLogin, launchAtLoginAvailable: launchAtLoginAvailable) {
            switch entry {
            case .open:
                menu.addItem(item("Open KeyKeeper", actions.open, target))
            case .lock:
                menu.addItem(item("Lock Vault", actions.lock, target))
            case .unlock:
                menu.addItem(item("Unlock Vault\u{2026}", actions.unlock, target))
            case .createVault:
                menu.addItem(item("Create Vault\u{2026}", actions.unlock, target))
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
