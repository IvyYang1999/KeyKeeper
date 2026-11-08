import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

/// 【曾经的 bug】2026-11-08 主力 Mac 验收 R1：菜单栏里编辑一把 key，光标在名称或密钥框里时按 Esc，
/// 整个弹层被关掉；重开还停在编辑页，草稿还在。只有没点过输入框时，Esc 才是取消。
/// 原因：有焦点的输入框把 Esc 变成 cancelOperation:，一路往上越过 SwiftUI 的「取消」按钮，
/// 弹层收到它就关闭。这里用离屏窗口走真实的 AppKit 按键路径，全部假数据。
@MainActor final class EditorEscapeTests: XCTestCase {
    /// Stands in for the popover: NSPopover closes when cancelOperation: reaches its window.
    final class PopoverStandIn: NSWindow {
        var closes = 0
        override func cancelOperation(_ sender: Any?) { closes += 1 }
    }

    private func host<V: View>(_ root: V, asView: Bool = false) -> PopoverStandIn {
        _ = NSApplication.shared
        let window = PopoverStandIn(contentRect: NSRect(x: -5000, y: -5000, width: 380, height: 500),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if asView {
            window.contentView = EscapeRoutingHostingView(rootView: root)
        } else {
            window.contentViewController = EscapeRoutingHostingController(rootView: root)
        }
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return window
    }

    private enum Focus: String { case name, secret, note }

    private func focus(_ kind: Focus, in window: NSWindow) throws {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let candidates = all(try XCTUnwrap(window.contentView)).filter(\.acceptsFirstResponder)
        let target: NSView? = switch kind {
        case .secret: candidates.first { $0 is NSSecureTextField }
        case .name: candidates.first { $0 is NSTextField && !($0 is NSSecureTextField) }
        case .note: candidates.first { $0 is NSTextView }
        }
        let view = try XCTUnwrap(target, "找不到 \(kind) 输入框")
        XCTAssertTrue(window.makeFirstResponder(view), "\(kind) 拿不到焦点")
    }

    private func pressEscape(in window: NSWindow) throws {
        let escape = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private struct Fields: View {
        @State var name = "Synthetic"
        @State var secret = "sk-synthetic-0001"
        @State var note = "synthetic note"
        var editing: Bool
        var onCancel: () -> Void
        var body: some View {
            VStack {
                TextField("Name", text: $name)
                SecureField("Secret", text: $secret)
                TextEditor(text: $note).frame(height: 40)
            }
            .padding()
            .frame(width: 300, height: 200)
            .background { if editing { CancelsOnEscape(action: onCancel) } }
        }
    }

    /// 【曾经的 bug】名称、密钥、备注三种输入框有焦点时按 Esc：取消编辑，弹层留着。
    func test曾经的Bug输入框有焦点时Esc取消编辑不关弹层() throws {
        for kind in [Focus.name, .secret, .note] {
            var cancels = 0
            let window = host(Fields(editing: true, onCancel: { cancels += 1 }))
            try focus(kind, in: window)
            try pressEscape(in: window)
            XCTAssertEqual(cancels, 1, "\(kind)：Esc 应取消编辑")
            XCTAssertEqual(window.closes, 0, "\(kind)：弹层不能被关掉")
            window.close()
        }
    }

    /// 输入法正在组字时，第一下 Esc 只结束组字，不取消编辑；再按一下才取消。
    func test输入法组字时第一下Esc只结束组字() throws {
        var cancels = 0
        let window = host(Fields(editing: true, onCancel: { cancels += 1 }))
        try focus(.name, in: window)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())

        try pressEscape(in: window)
        XCTAssertEqual(cancels, 0, "组字时 Esc 不应取消编辑")
        XCTAssertEqual(window.closes, 0)
        XCTAssertFalse(editor.hasMarkedText(), "组字应结束")

        try pressEscape(in: window)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(window.closes, 0)
        window.close()
    }

    /// 不在编辑时，Esc 照旧交给弹层（关闭它），不被吞掉。
    func test不在编辑时Esc照旧关弹层() throws {
        var cancels = 0
        let window = host(Fields(editing: false, onCancel: { cancels += 1 }))
        try focus(.name, in: window)
        try pressEscape(in: window)
        XCTAssertEqual(cancels, 0)
        XCTAssertEqual(window.closes, 1, "没有编辑器时 Esc 要照旧往上传")
        window.close()
    }

    /// 主窗口用的是 NSHostingView：有焦点时 Esc 同样取消编辑。
    func test主窗口输入框有焦点时Esc也取消编辑() throws {
        var cancels = 0
        let window = host(Fields(editing: true, onCancel: { cancels += 1 }), asView: true)
        try focus(.note, in: window)
        try pressEscape(in: window)
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(window.closes, 0)
        window.close()
    }

    /// 真实编辑页（菜单栏布局、直接进编辑）：名称框、备注框有焦点，或者没有焦点，Esc 都回到详情；什么都不写。
    func test曾经的Bug菜单栏编辑页Esc回到详情不保存() throws {
        for kind in [Focus?.some(.name), .some(.note), nil] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MetaStore(directory: dir)
            let credential = Credential(label: "Editor Synthetic", notes: "synthetic note", links: [],
                                        fields: ["token": .init(secret: true)], security: .standard,
                                        created: "2026-11-01", updated: "2026-11-01")
            try store.save(MetaFile(credentials: ["x": credential]))
            let session = NamingSession(values: ["x.token": "tk-synthetic-0001"])
            var backs = 0
            var updates = 0
            let editor = CredentialDetailView(
                credentialId: "x", credential: credential, session: session,
                onBack: { backs += 1 }, onUpdate: { updates += 1 }, onDelete: { nil },
                startEditing: true, store: store, approvals: .inMemory()
            )
            .environment(\.panelLayout, .popover)
            let window = host(editor)
            if let kind { try focus(kind, in: window) }
            try pressEscape(in: window)

            let label = kind.map(\.rawValue) ?? "无焦点"
            XCTAssertEqual(backs, 1, "\(label)：Esc 应取消编辑回到详情")
            XCTAssertEqual(window.closes, 0, "\(label)：弹层不能被关掉")
            XCTAssertEqual(updates, 0)
            let stored = try XCTUnwrap(store.load().credentials["x"])
            XCTAssertEqual(stored.label, "Editor Synthetic", "\(label)：取消不写任何东西")
            XCTAssertEqual(stored.notes, "synthetic note")
            XCTAssertEqual(stored.fields.keys.sorted(), ["token"])
            XCTAssertEqual(session.values, ["x.token": "tk-synthetic-0001"])
            window.close()
        }
    }
}
