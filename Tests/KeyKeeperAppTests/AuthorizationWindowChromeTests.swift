import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 透明磨砂面板（授权窗、保存确认面板）在内容展开/收起时的两条不变量。
///
/// 【曾经的 bug】yyt 2026-09-13：「展开调用详情之后，弹窗又变成这个奇怪的直角了」。
/// 窗口高度由 NSHostingView 的约束驱动，展开第一帧就跳到最终高度；而玻璃是 SwiftUI 的
/// `.background(GlassSurface)`，跟着内容走 0.3 秒展开动画。这 0.3 秒里窗口比玻璃高，
/// 上下各露一条：那里没有 NSVisualEffectView（不磨砂），玻璃自己的边缘又落在窗口中部
/// （拿不到窗口圆角），看起来就是直角实边。
@MainActor
final class AuthorizationWindowChromeTests: XCTestCase {
    /// 展开与收起的每一帧，磨砂都要和窗口内容区严丝合缝。
    func test曾经的Bug展开动画期间磨砂始终铺满窗口() throws {
        let model = PanelToggle()
        let (window, hosting) = Self.makePanelWindow(model: model)
        defer { window.close() }

        for expanded in [true, false] {
            withAnimation(.easeInOut(duration: 0.3)) { model.expanded = expanded }
            for _ in 0..<10 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.035))
                hosting.layoutSubtreeIfNeeded()
                let content = try XCTUnwrap(window.contentView).bounds
                let glass = try XCTUnwrap(Self.visualEffectViews(in: hosting).first)
                let rect = glass.convert(glass.bounds, to: window.contentView)
                XCTAssertEqual(rect.height, content.height, accuracy: 1,
                               "展开=\(expanded) 的动画途中玻璃比窗口矮了 \(content.height - rect.height)pt，露出的那条就是直角实边")
                XCTAssertEqual(rect.width, content.width, accuracy: 1)
            }
        }
    }

    /// 【曾经的 bug】2026-09-13 我给玻璃加 `.frame(maxHeight: .infinity)` 想让它铺满窗口，
    /// 结果拿掉了 NSHostingView 给窗口的最大高度约束：收起之后窗口再也缩不回去。
    func test曾经的Bug收起之后窗口高度缩回内容高度() throws {
        let model = PanelToggle()
        let (window, hosting) = Self.makePanelWindow(model: model)
        defer { window.close() }
        let collapsed = hosting.fittingSize.height

        withAnimation(.easeInOut(duration: 0.3)) { model.expanded = true }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(try XCTUnwrap(window.contentView).bounds.height, collapsed + 100, "展开后窗口应该长高")

        withAnimation(.easeInOut(duration: 0.3)) { model.expanded = false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.height, hosting.fittingSize.height, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.height, collapsed, accuracy: 1, "收起后应该缩回原来的高度")
    }

    // MARK: 同款窗口

    final class PanelToggle: ObservableObject {
        @Published var expanded = false
    }

    /// 和 AuthorizationWindowController / TrustPromptPresenter 同款：透明窗 + 全尺寸内容 +
    /// NSHostingView，内容用同一个 `glassPanel` 外壳。
    private struct PanelUnderTest: View {
        @ObservedObject var model: PanelToggle

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Authorization Request")
                if model.expanded {
                    Color.clear.frame(height: 220)
                }
                Text("Allow / Deny")
            }
            .padding(20)
            .glassPanel(width: 420)
        }
    }

    private static func makePanelWindow(model: PanelToggle) -> (NSWindow, NSHostingView<PanelUnderTest>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // Without this the window is deallocated by close() while the test still holds it,
        // which crashes the whole test process when the next case runs.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: PanelUnderTest(model: model))
        hosting.safeAreaRegions = []
        window.contentView = hosting
        window.setContentSize(hosting.fittingSize)
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))   // 不抢占屏幕
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    static func visualEffectViews(in view: NSView) -> [NSVisualEffectView] {
        var found: [NSVisualEffectView] = []
        if let effect = view as? NSVisualEffectView { found.append(effect) }
        for sub in view.subviews { found += visualEffectViews(in: sub) }
        return found
    }
}

/// 【又一次的方角】yyt 2026-09-13 晚：展开「调用方详情」之后整扇窗变成直角。
///
/// 上一次修的是动画期间的短暂错位。这次是另一回事：展开后的内容比屏幕还高，窗口被系统
/// 钳制住，而磨砂是按**内容高度**画的圆角矩形——于是可见范围里只剩它中间那一段，四个角
/// 全是直的。修法不是再去改玻璃，而是让内容超高时可以滚动，窗口永远不需要比屏幕高。
@MainActor
final class AuthorizationPanelHeightTests: XCTestCase {
    func test内容超高时窗口不超过可用高度() throws {
        let tall = VStack(spacing: 0) {
            ForEach(0..<200, id: \.self) { _ in Text("很长的一行内容").frame(height: 20) }
        }
        let limited = NSHostingView(rootView: tall.authorizationPanel(width: 420, maxHeight: 400))
        limited.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(limited.fittingSize.height, 400,
                                 "超高内容必须能滚动，否则窗口会被钳制、玻璃露出直边")
        XCTAssertEqual(limited.fittingSize.width, 420, accuracy: 1)
    }

    /// 内容不高时不该凭空长出空白——面板仍然贴着内容。
    func test内容不高时面板还是贴着内容() throws {
        let short = Text("一行").frame(height: 30)
        let view = NSHostingView(rootView: short.authorizationPanel(width: 420, maxHeight: 900))
        view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(view.fittingSize.height, 200, "短内容不该被撑到 maxHeight")
    }

    /// 磨砂要铺满可见内容区，两种高度下都要。
    func test两种高度下磨砂都铺满() throws {
        for (height, maxHeight) in [(20.0, 900.0), (4000.0, 400.0)] {
            let content = Color.clear.frame(height: height)
            let view = NSHostingView(rootView: content.authorizationPanel(width: 420, maxHeight: maxHeight))
            // Two passes, like the window: size to the content, let it measure, size again.
            for _ in 0..<2 {
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
            }
            XCTAssertLessThanOrEqual(view.bounds.height, maxHeight + 1, "高度 \(height)")
            let glass = try XCTUnwrap(AuthorizationWindowChromeTests.visualEffectViews(in: view).first)
            let rect = glass.convert(glass.bounds, to: view)
            XCTAssertEqual(rect.height, view.bounds.height, accuracy: 1, "高度 \(height)")
            XCTAssertEqual(rect.width, view.bounds.width, accuracy: 1, "高度 \(height)")
        }
    }
}

/// 【曾经的 bug】2026-09-15: the production authorizationPanel, unlike glassPanel, kept
/// transparent strips around its background after a disclosure resized the hosting window.
@MainActor
final class AuthorizationPanelResizeTests: XCTestCase {
    private struct Panel: View {
        @ObservedObject var model: AuthorizationWindowChromeTests.PanelToggle
        let cap: CGFloat

        var body: some View {
            VStack(alignment: .leading, spacing: 16) {
                Text("Synthetic authorization window")
                Text("Allow / Deny")
                DisclosureGroup(isExpanded: $model.expanded) {
                    Text(String(repeating: "Synthetic caller details that wrap over several lines. ", count: 16))
                        .fixedSize(horizontal: false, vertical: true)
                } label: {
                    Text("Details")
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 22)
            .authorizationPanel(width: 440, maxHeight: cap)
        }
    }

    func test反复展开收起真实面板容器背景不露直边() throws {
        _ = NSApplication.shared
        for cap in [CGFloat(700), 240] {
            let model = AuthorizationWindowChromeTests.PanelToggle()
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isOpaque = false
            window.backgroundColor = .clear
            window.isReleasedWhenClosed = false
            let hosting = AuthorizationWindowController.installContent(Panel(model: model, cap: cap), in: window)
            // Keep a real screen association: AppKit does not run the same resize constraints
            // for an off-screen window. Order behind other windows without activating the app.
            window.center()
            window.orderBack(nil)
            defer { window.close() }
            var collapsedHeight: CGFloat?

            for expanded in [false, true, false, true, false] {
                withAnimation(.easeInOut(duration: 0.3)) { model.expanded = expanded }
                for _ in 0..<12 {
                    runApplicationLoop(for: 0.035)
                    hosting.layoutSubtreeIfNeeded()
                    let content = try XCTUnwrap(window.contentView)
                    let glass = try XCTUnwrap(AuthorizationWindowChromeTests.visualEffectViews(in: hosting).first)
                    let rect = glass.convert(glass.bounds, to: content)
                    let inWindow = glass.convert(glass.bounds, to: nil)
                    XCTAssertEqual(rect.minY, content.bounds.minY, accuracy: 1, "cap=\(cap), expanded=\(expanded)")
                    XCTAssertEqual(rect.maxY, content.bounds.maxY, accuracy: 1, "cap=\(cap), expanded=\(expanded)")
                    XCTAssertEqual(rect.width, content.bounds.width, accuracy: 1)
                    XCTAssertEqual(inWindow.minY, 0, accuracy: 1, "Glass must reach the native window bottom")
                    XCTAssertEqual(inWindow.maxY, window.frame.height, accuracy: 1,
                                   "Glass must reach the native window top, not just the hosting view bounds")
                }
                XCTAssertLessThanOrEqual(window.frame.height, cap + 1)
                if !expanded {
                    if let collapsedHeight {
                        XCTAssertEqual(window.frame.height, collapsedHeight, accuracy: 1,
                                       "Repeated collapses must not accumulate title-bar height")
                    } else { collapsedHeight = window.frame.height }
                }
            }
        }
    }

    /// A plain RunLoop skips NSApplication's updateWindows/hosting-window resize pass.
    /// The bounded app loop reproduces what actually happens after clicking a disclosure.
    private func runApplicationLoop(for duration: TimeInterval) {
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { _ in
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                              modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: false)
            }
        }
        NSApp.run()
    }
}
