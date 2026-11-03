import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp

@MainActor
final class MainWindowRoutingTests: XCTestCase {
    /// 【曾经的 bug】原生 Settings 与控制台各有一扇设置窗；所有入口应复用控制台。
    func testSettingsMenuAndReopenReuseOneRealWindow() throws {
        _ = NSApplication.shared
        guard !UpdateConfiguration(bundle: .main).canStartUpdater(isIsolated: TestInstance.isIsolated) else {
            return XCTFail("This offscreen test must not start Sparkle")
        }
        let router = MainWindowRouter()
        var presented: [NSWindow] = []
        let controller = MainWindowController(router: router, frameAutosaveName: nil,
            presentWindow: { presented.append($0) }) { AnyView(Text("Synthetic console")) }
        let owner = RecordingDelegate()
        owner.show = { section in controller.show(section: section) }
        let menu = owner.makeApplicationMenu()
        let settings = try XCTUnwrap(items(in: menu).first { $0.keyEquivalent == "," })
        XCTAssertEqual(items(in: menu).filter { $0.keyEquivalent == "," }.count, 1)
        XCTAssertFalse(items(in: menu).contains { ["showSettingsWindow:", "showPreferencesWindow:"].contains($0.action.map(NSStringFromSelector) ?? "") })
        XCTAssertTrue(settings.target === owner)
        XCTAssertEqual(settings.keyEquivalentModifierMask, .command)
        XCTAssertEqual(router.section, .keys)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(router.section, .settings)
        XCTAssertEqual(presented.count, 1)
        let first = try XCTUnwrap(presented.first)
        XCTAssertFalse(first.isVisible, "Test presenter must stay offscreen")
        first.close()
        router.section = .keys
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(settings.action), to: settings.target, from: settings))
        XCTAssertEqual(router.section, .settings)
        XCTAssertEqual(presented.count, 2)
        XCTAssertTrue(presented.last === first)
        XCTAssertFalse(owner.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        XCTAssertEqual(presented.count, 3)
        XCTAssertTrue(presented.last === first)
        first.close()
    }

    func testAppMenuPreservesResponderEditingAndWindowShortcuts() throws {
        _ = NSApplication.shared
        let target = NSObject()
        let menu = AppMenuBuilder.build(target: target, settings: Selector(("settings")), newKey: Selector(("newKey")))
        let all = items(in: menu)
        for (key, selector) in [("x", "cut:"), ("c", "copy:"), ("v", "paste:"),
                                ("a", "selectAll:"), ("z", "undo:"), ("w", "performClose:"), ("m", "performMiniaturize:")] {
            let item = try XCTUnwrap(all.first { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command })
            XCTAssertEqual(item.action, Selector(selector))
            XCTAssertNil(item.target)
        }
        let redo = try XCTUnwrap(all.first { $0.keyEquivalent == "z" && $0.keyEquivalentModifierMask == [.command, .shift] })
        XCTAssertEqual(redo.action, Selector(("redo:")))
        XCTAssertNil(redo.target)
        for key in [",", "n"] { XCTAssertTrue(all.first { $0.keyEquivalent == key }?.target === target) }
        XCTAssertTrue(all.first { $0.keyEquivalent == "q" }?.target === NSApp)
    }

    func testStandardMenusAreRegisteredAndLocalized() throws {
        _ = NSApplication.shared
        let previous = (NSApp.mainMenu, NSApp.servicesMenu, NSApp.windowsMenu)
        defer {
            NSApp.mainMenu = previous.0
            NSApp.servicesMenu = previous.1
            NSApp.windowsMenu = previous.2
        }
        let target = NSObject()
        let en = AppMenuBuilder.build(target: target, settings: Selector(("settings")), newKey: Selector(("newKey")), language: "en")
        let zh = AppMenuBuilder.build(target: target, settings: Selector(("settings")), newKey: Selector(("newKey")), language: "zh-Hans")
        XCTAssertEqual(en.items.map(\.title), ["KeyKeeper", "File", "Edit", "Window"])
        XCTAssertEqual(zh.items.map(\.title), ["KeyKeeper", "文件", "编辑", "窗口"])
        XCTAssertEqual(items(in: zh).first { $0.keyEquivalent == "," }?.title, "设置…")
        XCTAssertEqual(items(in: zh).first { $0.keyEquivalent == "v" }?.title, "粘贴")
        AppMenuBuilder.install(zh, on: NSApp)
        XCTAssertTrue(NSApp.mainMenu === zh)
        XCTAssertTrue(NSApp.windowsMenu === zh.items.last?.submenu)
        XCTAssertTrue(NSApp.servicesMenu === items(in: zh).first { $0.identifier?.rawValue == "services" }?.submenu)
    }

    private func items(in menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(items(in:)) ?? []) }
    }
    private final class RecordingDelegate: AppDelegate {
        var show: ((MainWindowRouter.Section?) -> Void)?
        override func showMainWindow(section: MainWindowRouter.Section? = nil, credentialId: String? = nil) { show?(section) }
    }
}
