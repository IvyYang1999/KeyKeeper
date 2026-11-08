import AppKit
import SwiftUI

/// Esc cancels the edit on screen, also while a text field has focus.
///
/// 【曾经的 bug】2026-11-08 主力 Mac 验收 R1：菜单栏里编辑时光标在名称或密钥框里按 Esc，整个弹层被关掉，
/// 重开还停在编辑页、草稿还在。A focused field turns Esc into `cancelOperation:`, which climbs the
/// responder chain past SwiftUI (and past its Cancel button's shortcut) to the popover, which closes on it.
/// Only `NSWindow` implements `cancelOperation:`. The hosting controller (popover) and hosting view (main
/// window) below now offer it to an editor on screen first, and pass it on unchanged when there is none.
///
/// Put it behind the editor: `.background(CancelsOnEscape(action: cancel))`.
struct CancelsOnEscape: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> EscapeTargetView { EscapeTargetView(action: action) }
    func updateNSView(_ view: EscapeTargetView, context: Context) { view.action = action }
}

final class EscapeTargetView: NSView {
    var action: () -> Void
    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

enum EditorEscape {
    /// Handles Esc for the editor under `root`. False when there is no editor, so the caller passes it on.
    @MainActor static func handle(in root: NSView) -> Bool {
        guard let target = editor(in: root) else { return false }
        // An input method is composing: Esc ends the composition and nothing else.
        if let text = root.window?.firstResponder as? NSTextView, text.hasMarkedText() {
            text.inputContext?.discardMarkedText()
            if text.hasMarkedText() { text.unmarkText() }
            return true
        }
        target.action()
        return true
    }

    @MainActor private static func editor(in view: NSView) -> EscapeTargetView? {
        if let target = view as? EscapeTargetView, !target.isHiddenOrHasHiddenAncestor { return target }
        for child in view.subviews {
            if let found = editor(in: child) { return found }
        }
        return nil
    }

    /// What the responder chain would have done without us.
    @MainActor static func passOn(from responder: NSResponder, _ sender: Any?) {
        _ = responder.nextResponder?.tryToPerform(#selector(NSResponder.cancelOperation(_:)), with: sender)
    }
}

/// The menu bar popover's content.
final class EscapeRoutingHostingController<Content: View>: NSHostingController<Content> {
    override func cancelOperation(_ sender: Any?) {
        if EditorEscape.handle(in: view) { return }
        EditorEscape.passOn(from: self, sender)
    }
}

/// The main window's content.
final class EscapeRoutingHostingView<Content: View>: NSHostingView<Content> {
    override func cancelOperation(_ sender: Any?) {
        if EditorEscape.handle(in: self) { return }
        EditorEscape.passOn(from: self, sender)
    }
}
