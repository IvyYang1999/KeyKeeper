import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-08 渲染发现：主窗口拖到最窄（820 点）、key 名字又长时，详情页标题区的控制台链接
/// 被挤成一列一两个字母、「每次询问」被压成空色块；密钥卡片字段名固定 190 点，值一个字都不剩；左边列表
/// 「每次询问」「8 天后过期」折成三行。这里量的是真主窗口里这些东西实际拿到的尺寸。
@MainActor final class NarrowMainWindowLayoutTests: XCTestCase {
    func test曾经的Bug最窄主窗口里值和标签都看得见且不折行() throws {
        for language in ["zh-Hans", "en"] {
            for width in [820.0, 1120] {
                let probes = try measure(language: language, width: width)
                let context = "\(language) 宽 \(Int(width))：\(probes.mapValues { $0.map { "\(Int($0.width))×\(Int($0.height))" } })"
                let values = probes["detail.value"] ?? []
                XCTAssertEqual(values.count, 2, "两个字段的值都该量到。\(context)")
                XCTAssertGreaterThanOrEqual(values.map(\.width).min() ?? 0, 60, "值被挤没了。\(context)")
                for size in probes["detail.header.link"] ?? [] {
                    XCTAssertLessThanOrEqual(size.height, 24, "控制台链接折行了。\(context)")
                }
                for size in probes["detail.header.badge"] ?? [] {
                    XCTAssertLessThanOrEqual(size.height, 24, "标题区标签折行了。\(context)")
                    XCTAssertGreaterThanOrEqual(size.width, 50, "标题区标签被压扁了。\(context)")
                }
                XCTAssertFalse((probes["list.badge"] ?? []).isEmpty, context)
                for size in probes["list.badge"] ?? [] where size.height > 0 {
                    XCTAssertLessThanOrEqual(size.height, 24, "列表标签折行了。\(context)")
                }
            }
        }
    }

    private func measure(language: String, width: CGFloat) throws -> [String: [CGSize]] {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("narrow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetaStore(directory: directory, integrityIO: FakeKeychainIO())
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        var long = Credential(label: "Stripe 生产环境主账号（只读报表任务）", notes: "", links: [],
                              fields: ["restricted-reporting-secret-key": .init(secret: true),
                                       "account-id": .init(value: "acct_synthetic_0000000000", secret: false)],
                              security: .strict, created: "2026-10-01", updated: "2026-11-06", provider: "stripe")
        long.expires = ISO8601DateFormatter.string(from: Date().addingTimeInterval(8 * 86_400), timeZone: .current,
                                                   formatOptions: [.withFullDate])
        try store.save(MetaFile(credentials: ["stripe-reporting-production": long]))
        try session.save(credentialId: "stripe-reporting-production", fieldName: "restricted-reporting-secret-key",
                         value: "rk_live_synthetic_0000_9Zq4", security: .strict)

        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        defaults.setVolatileDomain([AppL10n.preferenceName: language], forName: UserDefaults.argumentDomain)

        final class Box { var probes: [String: [CGSize]] = [:] }
        let box = Box()
        let router = MainWindowRouter()
        router.selectedCredentialId = "stripe-reporting-production"
        let root = MainWindowView(router: router, updateController: UpdateController(driver: PreviewUpdateDriver()),
                                  session: session, browserSessions: nil, importFile: nil, onShowSetup: {},
                                  listModel: CredentialListViewModel(session: session, store: store),
                                  metaStore: store, approvals: .inMemory())
            .frame(width: width, height: 700)
            .environment(\.locale, AppL10n.locale(preference: language))
            .onPreferenceChange(LayoutProbes.self) { probes in box.probes = probes }
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: width, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = NSHostingView(rootView: root)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return box.probes
    }
}
