import SwiftUI

/// Design tokens for consistent visual language.
/// Reference: translucent card-based macOS utility app aesthetic.
enum DS {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
    }

    /// One size for every page, so the popover never jumps or clips when switching pages.
    enum Popover {
        static let width: CGFloat = 380
        static let height: CGFloat = 500
        static var size: CGSize { CGSize(width: width, height: height) }
    }

}

// MARK: - Card Modifier

extension View {
    /// Padded, full-width `.card` surface (see Glass.swift for the surface table).
    func dsCard(
        padding: CGFloat = DS.Spacing.lg,
        radius: CGFloat = DS.Radius.md
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(.card, radius: radius)
    }
}

// MARK: - Section Label

/// The small heading over a group of fields. Written as is, never upper-cased: in Chinese an
/// upper-cased "给 AGENT 的备注" or "ICLOUD 同步" only shouted the English half (yyt 2026-11-07).
struct SectionLabel: View {
    let text: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(text)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.secondary)
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.75))
            }
        }
    }
}

// MARK: - Input

extension View {
    /// The one text input look: a sunken well, no border. Every form field uses it, so a page
    /// never mixes white bordered boxes with grey wells.
    func dsInput(monospaced: Bool = false) -> some View {
        self
            .textFieldStyle(.plain)
            .font(monospaced ? .body.monospaced() : .body)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .surface(.inset, radius: DS.Radius.sm)
    }
}
