import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp

@MainActor
final class UpdatesSettingsVisualTests: XCTestCase {
    func test中英文离屏卡片覆盖开关与不可用状态() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_UPDATES_PREVIEW"] else {
            throw XCTSkip("Opt-in offscreen settings preview; no live updater")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let driver = PreviewUpdateDriver()
            let controller = UpdateController(driver: driver)
            XCTAssertTrue(controller.automaticallyDownloadsUpdates)
            for enabled in [true, false] {
                if !enabled {
                    controller.setAutomaticallyDownloadsUpdates(false)
                    XCTAssertFalse(controller.automaticallyDownloadsUpdates)
                    XCTAssertEqual(driver.writes, [false])
                }
                try render(controller, name: "\(language)-\(enabled ? "on" : "off")", output: output)
            }
            try render(UpdateController(driver: nil), name: "\(language)-unavailable", output: output)
        }
    }

    private func render(_ controller: UpdateController, name: String, output: String) throws {
        let root = UpdatesSettingsCard(updateController: controller)
            .padding(16).frame(width: 360)
            .background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: name.hasPrefix("en") ? .aqua : .darkAqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("updates-\(name).png"))
        XCTAssertGreaterThan(view.fittingSize.height, 100)
        XCTAssertLessThan(view.fittingSize.height, 300)
    }
}

@MainActor
private final class PreviewUpdateDriver: UpdateDriving {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true { didSet { writes.append(automaticallyDownloadsUpdates) } }
    var stateDidChange: ((UpdateDriverState) -> Void)?
    var writes: [Bool] = []
    func checkForUpdates() {}
}
