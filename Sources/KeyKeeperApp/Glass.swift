import AppKit
import SwiftUI

// MARK: - Glass design system
//
// KeyKeeper is pure frosted glass, like a system panel: no tint, no brand wash (the blue and
// yellow in the mockups were only the "desktop" behind the glass). Every translucent white in
// the app comes from the five surfaces below — nothing else picks its own opacity.
//
// | Surface     | Where                                         | Light                      | Dark                       |
// |-------------|-----------------------------------------------|----------------------------|----------------------------|
// | .base       | window / popover / panel backdrop             | blur + white 50 %          | blur + black 38 %          |
// | .card       | list rows, content cards, tiles, info cards   | white 30 % + white hairline| white 6 % + white hairline |
// | .raised     | the selected row, sidebar item, primary tile  | white 92 % + soft shadow   | white 16 % + soft shadow   |
// | .inset      | search field, command box, value wells        | black 4.5 % (sunken)       | white 6 % (sunken)         |
// | .attention  | requests waiting for the user                 | orange 10 % over card      | orange 16 % over card      |
//
// Selection is shown by lifting (.raised), never by a coloured ring. Separators inside cards
// use `Glass.separator`. Designed 2026-09-11 after yyt: "several different whites — we need a
// system that says which white goes where".
enum Surface {
    case base, card, raised, inset, attention
}

enum Glass {
    static func veil(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.38) : Color.white.opacity(0.5)
    }

    static func fill(_ surface: Surface, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch surface {
        case .base: return veil(scheme)
        case .card: return dark ? Color.white.opacity(0.06) : Color.white.opacity(0.30)
        case .raised: return dark ? Color.white.opacity(0.16) : Color.white.opacity(0.92)
        case .inset: return dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
        case .attention: return Color.orange.opacity(dark ? 0.16 : 0.10)
        }
    }

    static func stroke(_ surface: Surface, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch surface {
        case .card, .raised: return dark ? Color.white.opacity(0.10) : Color.white.opacity(0.55)
        case .attention: return Color.orange.opacity(0.28)
        case .base, .inset: return .clear
        }
    }

    /// Hairline between rows inside a card, and between window columns.
    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07)
    }
}

/// Behind-window blur for a whole window or panel.
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// `.base`: blur and an even veil — the whole backdrop of a window, panel or popover.
struct GlassSurface: View {
    var intensity: Double = 1   // kept for call sites; the surface carries no colour wash
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            GlassBackdrop()
            Glass.veil(scheme)
        }
        .ignoresSafeArea()
    }
}

private struct SurfaceModifier: ViewModifier {
    let surface: Surface
    let radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Glass.fill(surface, scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Glass.stroke(surface, scheme), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(surface == .raised ? 0.10 : 0), radius: 8, y: 3)
    }
}

/// A hairline divider using the design system's separator.
struct GlassSeparator: View {
    var vertical = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle()
            .fill(Glass.separator(scheme))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

extension View {
    /// Paint this view as one of the design system's surfaces.
    func surface(_ surface: Surface, radius: CGFloat = DS.Radius.md) -> some View {
        modifier(SurfaceModifier(surface: surface, radius: radius))
    }

    /// Card, or raised when selected — the common case of `surface(_:)`.
    func glassCard(radius: CGFloat = DS.Radius.md, selected: Bool = false, padding: CGFloat? = nil) -> some View {
        self
            .padding(padding ?? 0)
            .surface(selected ? .raised : .card, radius: radius)
    }

    /// Full-window glass (`.base`).
    ///
    /// The glass never animates. The window's height is driven by this view's layout and
    /// jumps to its new value on the first frame, so a glass that eased into place (a
    /// disclosure opening) left the window taller than the glass for the whole 0.3 s: that
    /// bare strip had no blur and put the glass's own square edge inside the window, which
    /// is the "square corners" yyt reported on 2026-09-13.
    func glassWindowBackground(intensity: Double = 1) -> some View {
        self.background(
            GlassSurface(intensity: intensity)
                .transaction { $0.animation = nil }
        )
    }

    /// Root chrome for a transparent panel window: a fixed width, glass behind everything.
    ///
    /// Deliberately no `.frame(maxHeight: .infinity)`: that would drop the hosting view's
    /// max-size constraint, so the window could never shrink back after a disclosure closed
    /// (and crashed AppKit's constraint pass on 2026-09-13).
    func glassPanel(width: CGFloat, intensity: Double = 1) -> some View {
        frame(width: width)
            .glassWindowBackground(intensity: intensity)
    }

    /// A panel that never needs to be taller than the space it has.
    ///
    /// 【曾经的 bug】yyt 2026-09-13 晚：展开「调用方详情」后整扇窗变成直角。The glass draws a
    /// rounded rectangle sized to the *content*; once the content is taller than the screen the
    /// window gets clamped and only the middle band of that rectangle is visible — four straight
    /// edges. Scrolling the overflow keeps the window inside the screen, so the glass corners are
    /// always the window's corners. The height is only a ceiling: short content still hugs.
    func authorizationPanel(width: CGFloat, maxHeight: CGFloat, intensity: Double = 1) -> some View {
        MeasuredScrollPanel(width: width, maxHeight: maxHeight, intensity: intensity) { self }
    }
}

/// A panel whose height is the content's height, capped at `maxHeight`; only content taller than
/// the cap scrolls.
///
/// 【曾经的 bug · 2026-09-14】the panel used to be `ScrollView { … }.frame(maxHeight:)`. A ScrollView
/// answers "as tall as you offer" to any proposal, and NSHostingView re-proposes the window's own
/// size on every layout, so each pass asked for a little more: the window walked from 558pt of
/// content up to the 932pt of the screen, 32pt a frame — traced with a backtrace in an isolated
/// instance (`NSHostingView.windowDidLayout → updateAnimatedWindowSize`). Fixed-size content has
/// one answer; the ScrollView only appears once the measured content exceeds the cap, and then
/// with an explicit height.
private struct MeasuredScrollPanel<Content: View>: View {
    let width: CGFloat
    let maxHeight: CGFloat
    let intensity: Double
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0
    @Environment(\.authorizationPanelSizeChanged) private var reportSize

    private var measured: some View {
        content()
            .frame(width: width)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
            })
    }

    var body: some View {
        Group {
            if contentHeight > maxHeight {
                ScrollView(.vertical) { measured }
                    .frame(width: width, height: maxHeight)
                    .scrollBounceBehavior(.basedOnSize)
            } else {
                measured.fixedSize(horizontal: false, vertical: true)
            }
        }
        .onPreferenceChange(ContentHeightKey.self) {
            contentHeight = $0
            reportSize?(CGSize(width: width, height: min($0, maxHeight)))
        }
        .glassWindowBackground(intensity: intensity)
    }
}

private struct AuthorizationPanelSizeHandlerKey: EnvironmentKey {
    static let defaultValue: ((CGSize) -> Void)? = nil
}

extension EnvironmentValues {
    var authorizationPanelSizeChanged: ((CGSize) -> Void)? {
        get { self[AuthorizationPanelSizeHandlerKey.self] }
        set { self[AuthorizationPanelSizeHandlerKey.self] = newValue }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Small grey section heading used across the glass surfaces.
struct GlassSectionTitle: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            if let trailing {
                Text(trailing)
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }
}
