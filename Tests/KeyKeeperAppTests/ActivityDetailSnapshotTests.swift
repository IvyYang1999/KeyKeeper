import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp

/// Opt-in PNGs of the detail panes with synthetic rows, for looking at copy density by eye.
@MainActor final class ActivityDetailSnapshotTests: XCTestCase {
    func test访问详情与插件卡片快照() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_DETAIL_PREVIEW"] else {
            throw XCTSkip("Opt-in synthetic UI snapshots")
        }
        _ = NSApplication.shared
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let talkative = AccessLogGroup(id: "g1", who: "com.darkconstant.console", credentialId: "feisou-admin",
            detail: "ADMIN_KEY", kind: .approvalRequired, count: 3, latest: now, fingerprint: "app:unsigned:path=abc",
            reason: "Collect the weekly report for the dashboard", command: "node report.mjs --token sk-live-xyz",
            entries: (0..<3).map { AccessLogEntry(id: "e\($0)", date: now.addingTimeInterval(-Double($0) * 3600),
                who: "com.darkconstant.console", credentialId: "feisou-admin", detail: "ADMIN_KEY", kind: .approvalRequired) })
        let silent = AccessLogGroup(id: "g2", who: "node", credentialId: "feisou-admin", detail: "ADMIN_KEY",
            kind: .missedApproval, count: 1, latest: now, entries: [
                AccessLogEntry(id: "e9", date: now, who: "node", credentialId: "feisou-admin", detail: "ADMIN_KEY", kind: .missedApproval)])
        let plugins = FileManager.default.temporaryDirectory.appendingPathComponent("kk-plugins-" + UUID().uuidString)
        for path in AgentPluginSetup.requiredFiles {
            let file = plugins.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{}".utf8).write(to: file)
        }
        defer { try? FileManager.default.removeItem(at: plugins) }
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua), ("dark", .dark, .darkAqua)] {
            let root = HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 18) { AccessHistoryDetail(group: talkative, currentStatus: .notApproved, label: "feisou-admin", openCredential: {}, approve: {}) }
                VStack(alignment: .leading, spacing: 18) { AccessHistoryDetail(group: silent, currentStatus: .notApproved, label: "feisou-admin", openCredential: {}) }
                AgentPluginsCard(setup: AgentPluginSetup(root: plugins)).frame(width: 360)
            }
            .padding(20).frame(width: 1180)
            .environment(\.colorScheme, scheme)
            .background(Color(nsColor: .windowBackgroundColor))
            let view = NSHostingView(rootView: root)
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("activity-detail-\(name).png"))
        }
    }
}
