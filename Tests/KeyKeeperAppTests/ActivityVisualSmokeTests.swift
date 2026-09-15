import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// Opt-in, bounded native interaction harness. Only synthetic metadata and in-memory stores.
/// Never points at the real vault, never reads secrets, never installs or restarts the app.
@MainActor final class ActivityVisualSmokeTests: XCTestCase {
    func testInteractiveSyntheticPages() throws {
        guard ProcessInfo.processInfo.environment["KEYKEEPER_ACTIVITY_UI_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in native interaction harness")
        }
        let store = ApprovalStore.inMemory()
        try store.setMode(.enforced)
        for index in 0..<12 {
            var grant = Approval(id: "fixture-approval-\(index)",
                subject: .init(fingerprint: "app:fixture-\(index % 2)", displayName: "演示 Agent"),
                target: .credential(id: "fixture-\(index)", fields: index % 2 == 0 ? ["key", "other"] : nil),
                duration: index == 3 ? .timed(Date().addingTimeInterval(-60)) : .always,
                createdAt: Date().addingTimeInterval(-Double(index * 120)),
                reason: "合成测试：读取报表，不涉及真实账户。",
                command: "node /synthetic/example/report-collector.mjs --format summary")
            grant.lastUsedAt = Date().addingTimeInterval(-Double(index * 60))
            try store.add(grant)
            for offset in 0..<3 {
                try store.recordAudit(.init(timestamp: Date().addingTimeInterval(-Double(index * 90 + offset)),
                    credentialId: "fixture-\(index)", fieldName: "key", subjectFingerprint: "app:fixture-\(index % 2)",
                    subjectDisplayName: "演示 Agent", mode: .enforced, decision: "prompt_required"))
            }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kk-activity-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = BrowserExtensionSetup(extensionFolder: directory, launcher: directory.appendingPathComponent("host"),
            manifestURL: directory.appendingPathComponent("registration.json"), expectedExtensionID: String(repeating: "a", count: 32))
        try Data("synthetic fixture, not executable".utf8).write(to: setup.launcher!)
        let sessionStore = BrowserSessionStore(io: FakeKeychainIO(), marker: VisualMarker())
        try sessionStore.save(.init(id: UUID().uuidString, origin: "https://example.com", label: "演示网站", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ]))
        let controller = BrowserSessionController(store: sessionStore, runtime: VisualRuntime(),
            present: { _, reply in reply(false) }, dismiss: {}, approvals: .inMemory())
        let emptyController = BrowserSessionController(store: BrowserSessionStore(io: FakeKeychainIO(), marker: VisualMarker()),
            runtime: VisualRuntime(), present: { _, reply in reply(false) }, dismiss: {}, approvals: .inMemory())
        let credentials = (0..<12).map { index in
            (id: "fixture-\(index)", credential: Credential(label: "演示凭据 \(index)", notes: "", links: [],
                fields: ["key": .init(secret: true), "other": .init(secret: true)], security: .standard,
                created: "2026-09-15", updated: "2026-09-15"))
        }
        let edits = (0..<25).map { index in
            MetadataChangeRecord(id: "edit-\(index)", caller: "演示 Agent", groupId: "fixture-0", label: "演示凭据 0",
                changes: [.titleChanged(from: "旧名称", to: "演示名称 \(index)"), .notesChanged],
                timestamp: Date().addingTimeInterval(-Double(index * 60)))
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "KeyKeeper · 合成界面测试"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 360)
        window.contentView = NSHostingView(rootView: VisualPages(store: store, credentials: credentials, edits: edits,
            sessions: controller, emptySessions: emptyController, setup: setup, window: window))
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 8 minutes to inspect click, keyboard, hover, resize and scroll. Close sooner with Done.
        let timer = Timer.scheduledTimer(withTimeInterval: 480, repeats: false) { _ in MainActor.assumeIsolated { Self.stop() } }
        defer { timer.invalidate(); window.close() }
        NSApp.run()
    }

    fileprivate static func stop() {
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: false) }
    }
}

@MainActor private struct VisualPages: View {
    let store: ApprovalStore
    let credentials: [(id: String, credential: Credential)]
    let edits: [MetadataChangeRecord]
    let sessions: BrowserSessionController
    let emptySessions: BrowserSessionController
    let setup: BrowserExtensionSetup
    let window: NSWindow
    @State private var page = "记录"
    @State private var opened = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("合成页面", selection: $page) {
                    ForEach(["记录", "权限", "登录态", "空登录态"], id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(width: 280)
                Button("窄窗口") { resize(680) }
                Button("宽窗口") { resize(1120) }
                Button("完成") { ActivityVisualSmokeTests.stop() }
                Text(opened).font(.caption)
            }.padding(8)
            Divider()
            switch page {
            case "权限": ApprovedCallersPage(credentials: credentials, state: PermissionPageState(store: store), onOpenCredential: { opened = "打开 " + $0 })
            case "登录态": BrowserSessionManagerView(controller: sessions, setup: setup)
            case "空登录态": BrowserSessionManagerView(controller: emptySessions, setup: setup)
            default: AccessLogPage(credentials: credentials, access: AccessLogApprovalState(store: store), loadEdits: { edits }, onOpenCredential: { opened = "打开 " + $0 })
            }
        }.background(Color(nsColor: .windowBackgroundColor)).environment(\.locale, AppL10n.locale)
    }
    private func resize(_ width: CGFloat) { var frame = window.frame; frame.size.width = width; window.setFrame(frame, display: true) }
}

private final class VisualMarker: BrowserSessionMarker, @unchecked Sendable {
    var value = false
    func wasCreated() throws -> Bool { value }
    func markCreated() throws { value = true }
}
@MainActor private final class VisualRuntime: BrowserSessionRuntime {
    var activeIDs: [String] = []
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool, completion: @escaping (Bool) -> Void) { completion(false) }
    func stop(id: String) {}
    func stopAll() {}
}
