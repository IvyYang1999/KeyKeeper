import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// Opt-in offscreen render of the menu bar home and the main window's key list. Synthetic
/// metadata in a temporary folder, fake Keychain, in-memory approvals, injected change log and
/// CLI state: nothing real is read and no window is shown.
@MainActor final class HomeAndWindowVisualTests: XCTestCase {
    func test菜单栏首页与主窗口列表中英文浅深色() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PANEL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic home and window render")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaStore(directory: directory, integrityIO: FakeKeychainIO())
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        let approvals = ApprovalStore.inMemory()

        func credential(_ label: String, _ provider: String?, _ fields: [String: CredentialField],
                        security: SecurityLevel = .standard, expires: String? = nil) -> Credential {
            var made = Credential(label: label, notes: "", links: [], fields: fields, security: security,
                                  created: "2026-11-01", updated: "2026-11-06", provider: provider)
            made.expires = expires
            return made
        }
        let secret = CredentialField(secret: true)
        let credentials: [String: Credential] = [
            "openai": credential("OpenAI 个人项目", "openai", ["api-key": secret, "org-id": .init(value: "org-synthetic", secret: false)]),
            "openai-work": credential("OpenAI 工作", "openai", ["api-key": secret]),
            "stripe-prod": credential("Stripe 生产", "stripe", ["secret-key": secret], security: .strict),
            "github": credential("GitHub", "github", ["token": secret], expires: "2026-11-20"),
            "x-api": credential("X", nil, ["consumer-key": secret, "consumer-secret": secret]),
            "quota": credential("配额看板", nil, ["api-key": secret]),
        ]
        try store.save(MetaFile(credentials: credentials))
        for (id, field, value) in [("openai", "api-key", "sk-synthetic-0000-a1Kk"), ("openai-work", "api-key", "sk-synthetic-1111-Zz09"),
                                   ("stripe-prod", "secret-key", "rk_test_synthetic_9Zq4"), ("github", "token", "ghp_synthetic_token_Ab12"),
                                   ("x-api", "consumer-key", "ck-synthetic-0001"), ("x-api", "consumer-secret", "cs-synthetic-0002")] {
            try session.save(credentialId: id, fieldName: field, value: value, security: .standard)
        }

        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (language, dark) in [("zh-Hans", false), ("en", true)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language, "setupComplete": true,
                                        "lastSeenMetadataChange": ""], forName: UserDefaults.argumentDomain)
            let suffix = "\(language)-\(dark ? "dark" : "light")"
            let change = MetadataChangeRecord(caller: "Claude Code", groupId: "openai", label: "OpenAI 个人项目",
                                              changes: [.titleChanged(from: "OpenAI", to: "OpenAI 个人项目"), .notesChanged])
            for (variant, notices) in [("clean", false), ("notices", true)] {
                let server = IPCServer(session: session, metaStore: store, approvals: approvals)
                let home = MainView(session: session, ipcServer: server,
                    listModel: CredentialListViewModel(session: session, store: store),
                    addModel: AddCredentialViewModel(session: session, store: store, approvals: approvals),
                    services: PopoverHomeServices(latestChange: { notices ? change : nil },
                                                  probeCLI: { notices ? .missing : .current(installed: "synthetic") },
                                                  refreshMissed: { _ in }))
                try render(home, name: "home-\(variant)-\(suffix)", size: NSSize(width: DS.Popover.width, height: 560),
                           dark: dark, language: language, layout: .popover, output: output)
            }

            for selected in [nil, "github"] as [String?] {
                let router = MainWindowRouter()
                router.section = .keys
                router.selectedCredentialId = selected
                let window = MainWindowView(router: router, updateController: UpdateController(driver: PreviewUpdateDriver()),
                    session: session, browserSessions: nil, importFile: nil, onShowSetup: {},
                    listModel: CredentialListViewModel(session: session, store: store), metaStore: store, approvals: approvals)
                try render(window, name: "window-\(selected ?? "none")-\(suffix)", size: NSSize(width: 1120, height: 760),
                           dark: dark, language: language, layout: .embedded, output: output)
            }
        }
    }

    private func render<V: View>(_ page: V, name: String, size: NSSize, dark: Bool, language: String,
                                 layout: PanelLayout, output: String) throws {
        let root = page
            .frame(width: size.width, height: size.height, alignment: .top)
            .environment(\.panelLayout, layout)
            .environment(\.locale, AppL10n.locale(preference: language))
            .environment(\.colorScheme, dark ? .dark : .light)
            .glassWindowBackground()
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        window.close()
    }
}
