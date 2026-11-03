import AppKit

/// AppKit owns the menu; custom settings/new-key actions use the same console owner.
@MainActor
enum AppMenuBuilder {
    static func build(target: AnyObject, settings: Selector, newKey: Selector,
                      language: String = AppL10n.language) -> NSMenu {
        func text(_ value: String) -> String { AppL10n.render(value, language: language) }
        func item(_ title: String, _ action: String, _ key: String = "",
                  target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let result = NSMenuItem(title: text(title), action: Selector(action), keyEquivalent: key)
            result.target = target
            result.keyEquivalentModifierMask = modifiers
            return result
        }
        func submenu(_ title: String, id: String? = nil) -> NSMenuItem {
            let result = NSMenuItem(title: text(title), action: nil, keyEquivalent: "")
            result.submenu = NSMenu(title: text(title))
            result.identifier = id.map { NSUserInterfaceItemIdentifier(rawValue: $0) }
            return result
        }
        let root = NSMenu()
        let app = submenu("KeyKeeper")
        root.addItem(app)
        let appMenu = app.submenu!
        appMenu.addItem(item("About KeyKeeper", "orderFrontStandardAboutPanel:", target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", NSStringFromSelector(settings), ",", target: target))
        appMenu.addItem(.separator())
        appMenu.addItem(submenu("Services", id: "services"))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Hide KeyKeeper", "hide:", "h", target: NSApp))
        appMenu.addItem(item("Hide Others", "hideOtherApplications:", "h", target: NSApp, modifiers: [.command, .option]))
        appMenu.addItem(item("Show All", "unhideAllApplications:", target: NSApp))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Quit KeyKeeper", "terminate:", "q", target: NSApp))

        let file = submenu("File")
        root.addItem(file)
        file.submenu!.addItem(item("New key group", NSStringFromSelector(newKey), "n", target: target))
        file.submenu!.addItem(item("Close", "performClose:", "w"))
        let edit = submenu("Edit")
        root.addItem(edit)
        edit.submenu!.addItem(item("Undo", "undo:", "z"))
        edit.submenu!.addItem(item("Redo", "redo:", "z", modifiers: [.command, .shift]))
        edit.submenu!.addItem(.separator())
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                     ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu!.addItem(item(title, action, key))
        }
        let window = submenu("Window", id: "window")
        root.addItem(window)
        window.submenu!.addItem(item("Minimize", "performMiniaturize:", "m"))
        window.submenu!.addItem(item("Zoom", "performZoom:"))
        window.submenu!.addItem(.separator())
        window.submenu!.addItem(item("Bring All to Front", "arrangeInFront:", target: NSApp))
        return root
    }

    static func install(_ menu: NSMenu, on application: NSApplication) {
        application.mainMenu = menu
        application.servicesMenu = menu.items.first?.submenu?.items.first { $0.identifier?.rawValue == "services" }?.submenu
        application.windowsMenu = menu.items.first { $0.identifier?.rawValue == "window" }?.submenu
    }
}
