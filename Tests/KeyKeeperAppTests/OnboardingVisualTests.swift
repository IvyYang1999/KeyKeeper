import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp

/// Opt-in offscreen renders of the welcome guide; no window, process, CLI probe or real data.
@MainActor
final class OnboardingVisualTests: XCTestCase {
    func testWelcomeGuideKeepsItsActionBarInsideThePopover() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_ONBOARDING_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic welcome render; no native window")
        }
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugins = AgentPluginSetup(root: root)
        let cases: [(String, Int?, CLIInstallState)] = [
            ("empty-missing", 0, .missing), ("keys-unverified", 12, .unverified(installed: "keykeeper unknown")),
            ("unknown-current", nil, .current(installed: "keykeeper ce7a8778a7dd"))
        ]
        for language in ["zh-Hans", "en"] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            for (name, count, cli) in cases {
                var complete = false
                let view = SetupView(setupComplete: Binding(get: { complete }, set: { complete = $0 }), keyCount: count,
                                     plugins: plugins, probeCLI: { cli })
                try render(view, name: "welcome-\(name)-\(language)", dark: language == "zh-Hans", output: output)
            }
            var complete = false
            let expanded = SetupView(setupComplete: Binding(get: { complete }, set: { complete = $0 }), keyCount: 0,
                                     plugins: plugins, probeCLI: { .failed(path: "/usr/local/bin/keykeeper") },
                                     scrolls: false, initialHosts: [.codex, .claude], initialShowImport: true)
            try render(expanded, name: "guide-expanded-\(language)", dark: language == "en", output: output)
            for host in AgentPluginSetup.Host.allCases {
                let steps = AgentHostSteps(host: host, setup: plugins).padding(12).frame(width: 340)
                try render(steps, name: "steps-\(host.rawValue)-\(language)", dark: false, output: output)
            }
        }
    }

    private func render<Content: View>(_ content: Content, name: String, dark: Bool, output: String) throws {
        let view = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        if name.hasPrefix("welcome") {
            XCTAssertEqual(view.fittingSize.width, DS.Popover.width, accuracy: 1, name)
            XCTAssertEqual(view.fittingSize.height, DS.Popover.height, accuracy: 1, "The guide must not grow past the popover: \(name)")
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
    }
}
