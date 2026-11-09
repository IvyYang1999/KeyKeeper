import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-07 yyt 盘点：菜单栏每行一个灰色「?」（还没检查值），7 行就是 7 个问号，像帮助按钮；
/// 详情页还有一整行「尚未检查值 / 重新检测」。现在只有缺值才标，其余状态什么都不显示。
final class CredentialAvailabilityBadgeTests: XCTestCase {
    func test只有缺值才显示标记() {
        XCTAssertFalse(CredentialAvailabilityBadge.isShown(.init(state: .unchecked)), "还没检查完不是你要处理的事")
        XCTAssertFalse(CredentialAvailabilityBadge.isShown(.init(state: .present)))
        XCTAssertFalse(CredentialAvailabilityBadge.isShown(.init(state: .unavailable)), "不弹授权就查不了，不代表丢了")
        XCTAssertTrue(CredentialAvailabilityBadge.isShown(.init(state: .missing, missingFields: ["api-key"])))
    }
}

/// Opt-in offscreen render of the menu bar list rows, the menu bar key page and the main window
/// key page. Synthetic metadata in a temporary folder, fake Keychain, in-memory approvals; no
/// window is shown and nothing real is read.
@MainActor final class PanelDetailVisualTests: XCTestCase {
    func test菜单栏列表详情与主窗口详情中英文浅深色() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PANEL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic menu bar and key page render")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaStore(directory: directory, integrityIO: FakeKeychainIO())
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        let approvals = ApprovalStore.inMemory()

        func credential(_ label: String, _ provider: String?, fields: [String: CredentialField],
                        notes: String = "", security: SecurityLevel = .standard) -> Credential {
            Credential(label: label, notes: notes, links: [], fields: fields, security: security,
                       created: "2026-11-01", updated: "2026-11-06", provider: provider)
        }
        let openai = credential("OpenAI 个人项目", "openai",
                                fields: ["api-key": .init(secret: true), "org-id": .init(value: "org-synthetic", secret: false)],
                                notes: "Personal projects only. Use the cheaper model for batch jobs.")
        let rows: [(id: String, credential: Credential, availability: CredentialValueAvailability)] = [
            ("openai", openai, .init(state: .unchecked)),
            ("stripe-prod", credential("Stripe 生产", "stripe", fields: ["secret-key": .init(secret: true)], security: .strict),
             .init(state: .present)),
            ("github", credential("GitHub", "github", fields: ["token": .init(secret: true)]), .init(state: .unavailable)),
            ("quota", credential("配额看板", nil, fields: ["api-key": .init(secret: true)]),
             .init(state: .missing, missingFields: ["api-key"])),
        ]
        try store.save(MetaFile(credentials: Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.credential) })))
        try session.save(credentialId: "openai", fieldName: "api-key", value: "sk-synthetic-0000-a1Kk", security: .standard)
        try session.save(credentialId: "stripe-prod", fieldName: "secret-key", value: "rk_test_synthetic_9Zq4", security: .strict)
        try session.save(credentialId: "github", fieldName: "token", value: "short-tok", security: .standard)
        let overview = try session.inspectValueOverview()

        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (language, dark) in [("zh-Hans", false), ("en", true)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let suffix = "\(language)-\(dark ? "dark" : "light")"

            let list = VStack(spacing: 0) {
                ForEach(rows, id: \.id) { row in
                    PopoverKeyRow(credential: row.credential,
                                  subtitle: ValueHintText.listSubtitle(row.credential.fieldSummary, credential: row.credential,
                                                                       hints: overview.hints[row.id] ?? [:]),
                                  valueAvailability: row.availability) {}
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            try render(list, name: "panel-list-\(suffix)", size: DS.Popover.size, dark: dark, language: language,
                       layout: .popover, output: output)

            for (index, availability) in [CredentialValueAvailability(state: .unchecked),
                                          .init(state: .missing, missingFields: ["api-key"])].enumerated() {
                let detail = PopoverKeyDetail(credentialId: "openai", credential: openai, session: session,
                                              valueAvailability: availability, valueHints: overview.hints["openai"] ?? [:],
                                              onBack: {}, onOpenWindow: {}, onEdit: {})
                try render(detail, name: "panel-detail-\(index == 0 ? "normal" : "missing")-\(suffix)",
                           size: NSSize(width: DS.Popover.width, height: 620), dark: dark, language: language,
                           layout: .popover, output: output)
            }

            let window = CredentialDetailView(credentialId: "openai", credential: openai, session: session,
                                              valueAvailability: .init(state: .unchecked),
                                              valueHints: overview.hints["openai"] ?? [:], onBack: {}, onUpdate: {},
                                              onDelete: { nil }, store: store, approvals: approvals)
            try render(window, name: "window-detail-\(suffix)", size: NSSize(width: 760, height: 980), dark: dark,
                       language: language, layout: .embedded, output: output)
        }
    }

    /// Busier keys: approved callers, old IDs, "ask every time", a service-account file.
    func test数据多的详情页() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PANEL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic busy detail render")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaStore(directory: directory, integrityIO: FakeKeychainIO())
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        let approvals = ApprovalStore.inMemory()
        var stripe = Credential(label: "Stripe 生产", notes: "Live payments. Read-only reporting jobs only.", links: [],
                                fields: ["secret-key": .init(secret: true)], security: .strict,
                                created: "2026-10-01", updated: "2026-11-06", provider: "stripe")
        stripe.aliases = ["stripe", "stripe-live"]
        let google = Credential(label: "GCP 部署机器人", notes: "", links: [],
                                fields: ["service-account": .init(secret: true, fileFormat: .serviceAccountJSON)], security: .standard,
                                created: "2026-10-01", updated: "2026-11-06", provider: nil)
        try store.save(MetaFile(credentials: ["stripe-prod": stripe, "gcp-deploy": google]))
        try session.save(credentialId: "stripe-prod", fieldName: "secret-key", value: "rk_live_synthetic_0000_9Zq4", security: .strict)
        try session.save(credentialId: "gcp-deploy", fieldName: "service-account",
                         value: #"{"type":"service_account","client_email":"deploy-bot@synthetic-project.iam.gserviceaccount.com","project_id":"synthetic-project"}"#,
                         security: .standard)
        let now = Date()
        for (fingerprint, name, duration) in [("app:com.anthropic.claude-code", "Claude Code", ApprovalDuration.always),
                                             ("app:com.openai.codex", "Codex", .timed(now.addingTimeInterval(3 * 86_400)))] {
            try approvals.add(Approval(id: "grant-\(name)", subject: ApprovalSubject(fingerprint: fingerprint, displayName: name),
                target: .credential(id: "stripe-prod", fields: nil), duration: duration,
                createdAt: now.addingTimeInterval(-86_400), lastUsedAt: now.addingTimeInterval(-600)))
        }
        let overview = try session.inspectValueOverview()
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (language, dark) in [("zh-Hans", false), ("en", true)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let suffix = "\(language)-\(dark ? "dark" : "light")"
            for (id, credential) in [("stripe-prod", stripe), ("gcp-deploy", google)] {
                let window = CredentialDetailView(credentialId: id, credential: credential, session: session,
                    valueAvailability: .init(state: .present), valueHints: overview.hints[id] ?? [:],
                    onBack: {}, onUpdate: {}, onDelete: { nil }, store: store, approvals: approvals)
                try render(window, name: "busy-window-\(id)-\(suffix)", size: NSSize(width: 760, height: 1200), dark: dark,
                           language: language, layout: .embedded, output: output)
                let panel = PopoverKeyDetail(credentialId: id, credential: credential, session: session,
                    valueAvailability: .init(state: .present), valueHints: overview.hints[id] ?? [:],
                    onBack: {}, onOpenWindow: {}, onEdit: {}, store: store, approvals: approvals)
                try render(panel, name: "busy-panel-\(id)-\(suffix)", size: NSSize(width: DS.Popover.width, height: 640), dark: dark,
                           language: language, layout: .popover, output: output)
                // The editor shares the add page's fields (white boxes since 2026-11-09).
                let editor = CredentialDetailView(credentialId: id, credential: credential, session: session,
                    valueAvailability: .init(state: .present), valueHints: overview.hints[id] ?? [:],
                    onBack: {}, onUpdate: {}, onDelete: { nil }, startEditing: true, store: store, approvals: approvals)
                try render(editor, name: "busy-edit-popover-\(id)-\(suffix)", size: NSSize(width: DS.Popover.width, height: 720),
                           dark: dark, language: language, layout: .popover, output: output)
            }
        }
    }

    func test添加页菜单栏与主窗口中英文() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_PANEL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic add page render")
        }
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: output).appendingPathComponent("fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaStore(directory: directory, integrityIO: FakeKeychainIO())
        try store.save(MetaFile(credentials: [:]))
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        for (language, dark) in [("zh-Hans", false), ("en", true)] {
            defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)
            let suffix = "\(language)-\(dark ? "dark" : "light")"
            for kind in ["blank", "stripe", "filled"] {
                let vm = AddCredentialViewModel(session: session, store: store, approvals: .inMemory())
                if kind == "stripe" { _ = vm.selectProvider(kind) }
                // The state from the 2026-11-09 screenshot: a name typed, one value pasted with the
                // first key left unnamed, and an empty second row.
                if kind == "filled" {
                    vm.label = "野草云"
                    vm.autoGenerateId()
                    vm.fields[0].value = "20-synthetic-0044"
                    vm.fields.append(FieldEntry())
                }
                let page = AddCredentialView(vm: vm, onSave: {}, onCancel: {}, onOpenExisting: { _ in })
                try render(page, name: "add-popover-\(kind)-\(suffix)", size: NSSize(width: DS.Popover.width, height: 720),
                           dark: dark, language: language, layout: .popover, output: output)
                try render(page, name: "add-window-\(kind)-\(suffix)", size: NSSize(width: 760, height: 900),
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
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: output).appendingPathComponent("\(name).png"))
        window.close()
    }
}
