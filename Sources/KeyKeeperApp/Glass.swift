import AppKit
import SwiftUI

/// KeyKeeper's frosted-glass look: pure frosted glass, like a system panel. The blue and
/// yellow in the mockups were only the "desktop" behind the glass to show its texture;
/// the app itself adds no tint (yyt, 2026-09-11).
enum Glass {
    static let selectionStroke = Color(red: 1.0, green: 0.75, blue: 0.0)

    // What makes system glass look refined: heavy blur, then an even veil so whatever is
    // behind reads only as soft colour, never as shapes. Cards sit on that veil and are
    // nearly opaque, so text never floats over a dark patch of the desktop.
    static func veil(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.28) : Color.white.opacity(0.5)
    }
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.08) : Color.white.opacity(0.78)
    }
    static func cardStroke(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.95)
    }
    // Light-mode values, for the few call sites without an environment.
    static let cardFill = Color.white.opacity(0.78)
    static let cardStroke = Color.white.opacity(0.95)
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

/// Blur and an even veil — the whole backdrop of a window, panel or popover. No tint.
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

private struct GlassCardModifier: ViewModifier {
    let radius: CGFloat
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.white.opacity(scheme == .dark ? 0.16 : 0.97) : Glass.cardFill(scheme))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Glass.selectionStroke.opacity(0.9) : Glass.cardStroke(scheme),
                                  lineWidth: selected ? 1.5 : 0.75)
            )
            .shadow(color: .black.opacity(selected ? 0.08 : 0.04), radius: selected ? 8 : 3, y: selected ? 3 : 1)
    }
}

extension View {
    /// Frosted card: nearly opaque white with a hairline white edge. `selected` adds the
    /// icon-yellow ring used for the current row.
    func glassCard(radius: CGFloat = DS.Radius.md, selected: Bool = false, padding: CGFloat? = nil) -> some View {
        self
            .padding(padding ?? 0)
            .modifier(GlassCardModifier(radius: radius, selected: selected))
    }

    /// Full-window glass: blur and veil.
    func glassWindowBackground(intensity: Double = 1) -> some View {
        self.background(GlassSurface(intensity: intensity))
    }
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
