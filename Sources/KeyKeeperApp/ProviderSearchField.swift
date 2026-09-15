import AppKit
import SwiftUI

/// AppKit owns text editing on macOS. Handle field-editor commands here: SwiftUI's outer
/// onMoveCommand does not receive arrow keys while its TextField is editing.
struct ProviderSearchField: NSViewRepresentable {
    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.delegate = context.coordinator
        field.placeholderString = L("Search name or alias")
        field.setAccessibilityIdentifier("provider-search")
        field.setAccessibilityLabel(L("Search name or alias"))
        field.recentsAutosaveName = nil
        field.maximumRecents = 0
        field.sendsSearchStringImmediately = true
        field.controlSize = .large
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        context.coordinator.owner = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class SearchField: NSSearchField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { window.makeFirstResponder(self) }
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var owner: ProviderSearchField
        init(_ owner: ProviderSearchField) { self.owner = owner }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            owner.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            // Let an input method finish composing before treating Return/arrows as navigation.
            guard !textView.hasMarkedText() else { return false }
            switch command {
            case #selector(NSResponder.moveDown(_:)): owner.onMove(1)
            case #selector(NSResponder.moveUp(_:)): owner.onMove(-1)
            case #selector(NSResponder.insertNewline(_:)): owner.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): owner.onCancel()
            default: return false
            }
            return true
        }
    }
}
