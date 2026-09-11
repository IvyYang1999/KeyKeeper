import SwiftUI

/// Where a page is being shown. The same credential, add and settings views live both in
/// the 380×500 menu bar popover and inside the main window; only the chrome differs.
enum PanelLayout {
    /// Fixed popover size, with a Back button.
    case popover
    /// Fills a main-window column; navigation comes from the sidebar and list instead.
    case embedded
}

private struct PanelLayoutKey: EnvironmentKey {
    static let defaultValue = PanelLayout.popover
}

extension EnvironmentValues {
    var panelLayout: PanelLayout {
        get { self[PanelLayoutKey.self] }
        set { self[PanelLayoutKey.self] = newValue }
    }
}

private struct PanelFrame: ViewModifier {
    @Environment(\.panelLayout) private var layout

    func body(content: Content) -> some View {
        switch layout {
        case .popover:
            content.frame(width: DS.Popover.width, height: DS.Popover.height)
        case .embedded:
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

extension View {
    /// Popover size in the menu bar, flexible inside the main window.
    func panelFrame() -> some View { modifier(PanelFrame()) }
}
