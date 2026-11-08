import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

/// Opt-in render of the whole settings page: synthetic services only, no Keychain, approvals, login items or iCloud.
@MainActor final class SettingsPageVisualTests: XCTestCase {
    func test设置页四组中英文浅深色() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_SETTINGS_PREVIEW"] else { throw XCTSkip("Opt-in synthetic settings render") }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let plugins = FileManager.default.temporaryDirectory.appendingPathComponent("kk-plugins-" + UUID().uuidString)
        for path in AgentPluginSetup.requiredFiles {
            let file = plugins.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
        }
        defer { try? FileManager.default.removeItem(at: plugins) }

        let paused = ICloudSyncPresentation(phase: .paused, enabled: true,
            lastSuccess: Date(timeIntervalSince1970: 1_793_600_000), issue: .networkUnavailable,
            missingCredentialCount: 48, missingFieldCount: 96)
        let ready = ICloudSyncPresentation(phase: .ready, enabled: true, lastSuccess: Date(timeIntervalSince1970: 1_793_600_000))
        let cases: [(String, String, Bool, ICloudSyncPresentation, Bool)] = [
            ("zh-paused-light", "zh-Hans", false, paused, false),
            ("zh-ready-dark", "zh-Hans", true, ready, true),
            ("en-off-light", "en", false, ICloudSyncPresentation(), false),
            ("en-paused-dark", "en", true, paused, false),
        ]
        for (name, language, dark, cloud, reviewerOn) in cases {
            defaults.setVolatileDomain([AppL10n.preferenceName: language, ApprovalAlertPreferences.soundKey: false],
                                       forName: UserDefaults.argumentDomain)
            let approvals = ApprovalStore.inMemory()
            let reviewer = ReviewerService(store: approvals)
            if reviewerOn { reviewer.isEnabled = true }
            let services = SettingsServices(
                approvals: approvals, reviewer: reviewer,
                loginItemAvailable: { true }, loginItemEnabled: { true },
                setLoginItem: { _ in XCTFail("render must not change login items") },
                probeCLI: { .current(installed: "keykeeper synthetic") },
                installCLI: { XCTFail("render must not install"); return nil },
                showDataFolder: { XCTFail("render must not open Finder") },
                agentPlugins: AgentPluginSetup(root: plugins))
            let page = SettingsPage(updateController: UpdateController(driver: PreviewUpdateDriver()),
                                    cloudState: cloud, cloudAction: { _ in XCTFail("render must not sync") },
                                    services: services, onShowServiceGrants: {}, onShowSetup: {})
                .padding(.top, 12)
                .frame(width: 640, height: reviewerOn ? 1500 : 1250, alignment: .top)
                .environment(\.panelLayout, .embedded)
                .environment(\.locale, AppL10n.locale(preference: language))
                .environment(\.colorScheme, dark ? .dark : .light)
                .glassWindowBackground()
            let view = NSHostingView(rootView: page)
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            view.frame = NSRect(x: 0, y: 0, width: 640, height: reviewerOn ? 1500 : 1250)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("settings-\(name).png"))
        }
    }
}
