import AppKit
import SwiftUI

/// KeyKeeper's frosted-glass look: the desktop shows through a light blur, with a faint
/// wash of the icon's yellow and the system blue so the brand reads even on a plain wallpaper.
/// Kept deliberately pale — the first mockups' light tint, not the saturated second pass.
enum Glass {
    static let washYellow = Color(red: 0.99, green: 0.91, blue: 0.66)
    static let washBlue = Color(red: 0.74, green: 0.84, blue: 0.98)
    static let cardFill = Color.white.opacity(0.55)
    static let cardStroke = Color.white.opacity(0.85)
    static let selectionStroke = Color(red: 1.0, green: 0.75, blue: 0.0)
}

/// Behind-window blur for a whole window or panel.
struct GlassBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground

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

/// The pale yellow / blue wash laid over the blur.
struct BrandWash: View {
    var intensity: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                RadialGradient(colors: [Glass.washYellow.opacity(0.55 * intensity), .clear],
                               center: UnitPoint(x: 0.12, y: 0.08),
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.75)
                RadialGradient(colors: [Glass.washBlue.opacity(0.6 * intensity), .clear],
                               center: UnitPoint(x: 0.92, y: 0.95),
                               startRadius: 0, endRadius: max(size.width, size.height) * 0.8)
            }
        }
        .allowsHitTesting(false)
    }
}

extension View {
    /// Frosted card: translucent white with a hairline white edge. `selected` adds the
    /// icon-yellow ring used for the current row.
    func glassCard(radius: CGFloat = DS.Radius.md, selected: Bool = false, padding: CGFloat? = nil) -> some View {
        self
            .padding(padding ?? 0)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(selected ? Color.white.opacity(0.92) : Glass.cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(selected ? Glass.selectionStroke.opacity(0.85) : Glass.cardStroke,
                                  lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(selected ? 0.08 : 0.03), radius: selected ? 10 : 2, y: selected ? 4 : 1)
    }

    /// Full-window glass: blur plus the brand wash.
    func glassWindowBackground(intensity: Double = 1) -> some View {
        self.background(
            ZStack {
                GlassBackdrop()
                BrandWash(intensity: intensity)
            }
            .ignoresSafeArea()
        )
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
