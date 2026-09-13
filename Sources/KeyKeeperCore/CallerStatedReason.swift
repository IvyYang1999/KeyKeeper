import Foundation

/// A sentence the calling process wrote for the authorization prompt: why it wants the key.
///
/// It is a *statement by the caller*, not a fact KeyKeeper verified — the same process that
/// wants the value writes it. So it is treated as hostile text: folded to a single line,
/// stripped of anything that can fake interface elements (control characters, zero-width
/// characters, bidi overrides), capped in length, rendered as plain text, and never allowed
/// to influence any decision. It is shown only in a prompt the user was going to see anyway.
public struct CallerStatedReason: Codable, Sendable, Equatable {
    /// Counted in characters, so Chinese text and emoji are never cut in half.
    public static let maximumLength = 200

    public var text: String
    /// True when the original was longer than `maximumLength`, so the prompt can say so.
    public var truncated: Bool

    public init(text: String, truncated: Bool = false) {
        self.text = text
        self.truncated = truncated
    }

    /// Nil when nothing usable is left. Idempotent: sanitizing a sanitized value changes nothing.
    public static func sanitize(_ raw: String?) -> CallerStatedReason? {
        guard let raw else { return nil }

        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                scalars.append(" ")            // every kind of whitespace becomes one space
                continue
            }
            // Controls, format characters (zero-width joiners/marks, bidi overrides) and
            // private-use scalars can all draw or reorder things the user did not write.
            if CharacterSet.controlCharacters.contains(scalar) { continue }
            if scalar.properties.generalCategory == .format { continue }
            if scalar.properties.generalCategory == .privateUse { continue }
            if scalar.value == 0xFEFF { continue }
            scalars.append(scalar)
        }

        let collapsed = String(String.UnicodeScalarView(scalars))
            .replacing(#/ {2,}/#, with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }

        let truncated = collapsed.count > maximumLength
        return CallerStatedReason(text: truncated ? String(collapsed.prefix(maximumLength)) : collapsed,
                                  truncated: truncated)
    }
}
