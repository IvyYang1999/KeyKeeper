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

    enum Fill {
        static let card = Color.primary.opacity(0.06)
        static let cardSecondary = Color.primary.opacity(0.04)
        static let codeBlock = Color.black.opacity(0.06)
    }
}

// MARK: - Card Modifier

extension View {
    func dsCard(
        padding: CGFloat = DS.Spacing.lg,
        fill: Color = DS.Fill.card,
        radius: CGFloat = DS.Radius.md
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// MARK: - Section Label (uppercase field label style)

struct SectionLabel: View {
    let text: String
    var hint: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
            Text(text.uppercased())
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .tracking(0.5)
            if let hint {
                Text(hint)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.6))
            }
        }
    }
}
