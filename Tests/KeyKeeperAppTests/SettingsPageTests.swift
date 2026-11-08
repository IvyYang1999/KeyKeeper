import AppKit
import SwiftUI
import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// The settings page with synthetic services: opening it reads, and never writes or acts.
@MainActor final class SettingsPageTests: XCTestCase {
    private let approvalsItem = "com.keykeeper.test.credentials.approvals"

    /// Opens the page once; returns the store and how many Keychain writes the opening made.
    private func open(reviewer stored: ReviewerSettings?) throws -> (ApprovalStore, writes: Int) {
        _ = NSApplication.shared
        let keychain = FakeKeychain()
        let approvals = ApprovalStore.inMemory(keychain)
        if let stored { try approvals.setReviewerSettings(stored) }
        _ = try approvals.mode()
        let before = keychain.writeCount(approvalsItem)
        let reviewer = ReviewerService(store: approvals)
        let services = SettingsServices(
            approvals: approvals, reviewer: reviewer,
            loginItemAvailable: { true }, loginItemEnabled: { false },
            setLoginItem: { _ in XCTFail("opening must not change login items") },
            probeCLI: { .missing },
            installCLI: { XCTFail("opening must not install"); return nil },
            showDataFolder: { XCTFail("opening must not open Finder") },
            agentPlugins: AgentPluginSetup(root: nil))
        let page = SettingsPage(updateController: UpdateController(driver: PreviewUpdateDriver()),
                                cloudState: .init(phase: .paused, enabled: true, issue: .networkUnavailable),
                                cloudAction: { _ in XCTFail("opening must not sync") },
                                services: services, onShowServiceGrants: { XCTFail() }, onShowSetup: { XCTFail() })
            .frame(width: 640, height: 1400)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 640, height: 1400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: page)
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        window.close()
        return (approvals, keychain.writeCount(approvalsItem) - before)
    }

    /// 打开设置页只读不写。以前载入时把「先询问我」开关设成存储里的值，onChange 随即把同样的模式
    /// 又写回钥匙串：每打开一次设置页就写一次授权钥匙串条目。
    func test打开设置页不往钥匙串写任何东西() throws {
        let (untouched, writes) = try open(reviewer: nil)
        XCTAssertEqual(writes, 0, "打开设置页不该写授权钥匙串条目")
        XCTAssertNil(try untouched.reviewerSettings(), "没开审查员时，不该写出审查员设置")

        // Enabled with blank address and model: the page shows the defaults but keeps them blank.
        let stored = ReviewerSettings(enabled: true, baseURL: "", model: "")
        let (enabled, writesWithReviewer) = try open(reviewer: stored)
        XCTAssertEqual(writesWithReviewer, 0)
        XCTAssertEqual(try enabled.reviewerSettings(), stored, "默认地址、模型只显示，不写回")
    }

    /// 【曾经的 bug】2026-11-08 主力 Mac 验收 follow-up：在设置页切换界面语言后，部分子标题还停在原来的语言，
    /// 离开设置再进来才对。文案是在 body 里按当时的偏好取的，输入没变的子视图不会重画。
    /// 这里比的是像素：当场切到中文的页面，和一打开就是中文的页面，应该一模一样。
    func test曾经的Bug切换界面语言后整页立刻换成新语言() throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard
        let key = AppL10n.preferenceName
        let original = defaults.object(forKey: key)
        defer { if let original { defaults.set(original, forKey: key) } else { defaults.removeObject(forKey: key) } }

        func page() -> some View {
            let approvals = ApprovalStore.inMemory(FakeKeychain())
            let services = SettingsServices(
                approvals: approvals, reviewer: ReviewerService(store: approvals),
                loginItemAvailable: { true }, loginItemEnabled: { false }, setLoginItem: { _ in },
                probeCLI: { .missing }, installCLI: { nil }, showDataFolder: {},
                agentPlugins: AgentPluginSetup(root: nil))
            return LanguageScoped(content: SettingsPage(
                updateController: UpdateController(driver: PreviewUpdateDriver()),
                cloudState: .init(phase: .paused, enabled: true, issue: .networkUnavailable),
                cloudAction: { _ in }, services: services, onShowServiceGrants: {}, onShowSetup: {}))
                .frame(width: 640, height: 1400)
        }
        func pixels(_ view: NSView) throws -> Data {
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func show(_ view: NSView) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 640, height: 1400),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.appearance = NSAppearance(named: .aqua)
            window.contentView = view
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            return window
        }

        defaults.set("en", forKey: key)
        let switched = NSHostingView(rootView: page())
        let first = show(switched)
        defer { first.close() }
        defaults.set("zh-Hans", forKey: key)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        let fresh = NSHostingView(rootView: page())
        let second = show(fresh)
        defer { second.close() }

        XCTAssertEqual(try pixels(switched), try pixels(fresh), "当场切换后的中文页面和新开的中文页面不一样：有文字还停在英文")
    }

    /// 设置页每一句界面文案都有中文。
    func test设置页文案都有中文() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pattern = try NSRegularExpression(pattern: #"L\("([^"\\]*)"\)"#)
        for file in ["SettingsView", "SettingsComponents", "ICloudSyncSettingsCard", "UpdatesSettingsCard", "AgentPluginsCard"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/\(file).swift"), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                let key = (source as NSString).substring(with: match.range(at: 1))
                XCTAssertNotEqual(AppL10n.render(key, language: "zh-Hans"), key, "\(file): \(key)")
            }
        }
    }
}
