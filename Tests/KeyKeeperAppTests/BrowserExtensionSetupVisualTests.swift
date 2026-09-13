import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Opt-in rendering of the "Website sessions" empty state, so the copy can be read at the size
/// it will actually be read at. Synthetic paths only; touches no real Chrome profile.
@MainActor final class BrowserExtensionSetupVisualTests: XCTestCase {
    func testRenderExtensionSetupCard() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_EXTENSION_PREVIEW"] else {
            throw XCTSkip("Opt-in visual inspection, synthetic paths only")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID())")
        let folder = root.appendingPathComponent("browser-extension")
        let launcher = root.appendingPathComponent("browser-native-host")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: launcher)
        defer { try? FileManager.default.removeItem(at: root) }

        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }

        for language in ["zh-Hans", "en"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            for (name, manifest) in [("not-connected", root.appendingPathComponent("absent.json")),
                                     ("connected", root.appendingPathComponent("host.json"))] {
                var setup = BrowserExtensionSetup(extensionFolder: folder, launcher: launcher, manifestURL: manifest)
                if name == "connected" { try setup.connect(extensionID: String(repeating: "d", count: 32)) }
                let view = NSHostingView(rootView:
                    BrowserSessionStartCard(setup: .constant(setup), onLogIn: {})
                        .padding(20)
                        .frame(width: 680))
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent("extension-\(name)-\(language).png"))
                XCTAssertGreaterThan(view.fittingSize.height, 60)
            }
        }
    }
}
