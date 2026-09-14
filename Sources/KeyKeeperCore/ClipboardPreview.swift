import Foundation

/// What the person is shown about the clipboard before a save — enough to recognise the value,
/// never enough to reconstruct it.
///
/// yyt 2026-09-14: the "copy exactly once after the request" rule protected against saving the
/// wrong thing, and made the flow unusable ("I had already copied it, and closed the window").
/// The replacement is to show the person what would be saved: the first four and last three
/// characters, the length, and whether it looks like prose (lines, spaces). Short values show
/// no characters at all. The full text is read once for this and not kept.
public struct ClipboardPreview: Equatable, Sendable {
    public var head: String
    public var tail: String
    public var shape: ValueShape
    /// When the clipboard last changed, if KeyKeeper was running to see it.
    public var copiedAt: Date?

    /// Values shorter than this show only their length.
    public static let minimumLengthToReveal = 12

    public init(head: String, tail: String, shape: ValueShape, copiedAt: Date? = nil) {
        self.head = head
        self.tail = tail
        self.shape = shape
        self.copiedAt = copiedAt
    }

    public static func masked(_ value: String) -> ClipboardPreview {
        let shape = ValueShape.of(value)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLengthToReveal else {
            return ClipboardPreview(head: "", tail: "", shape: shape)
        }
        return ClipboardPreview(head: String(trimmed.prefix(4)), tail: String(trimmed.suffix(3)), shape: shape)
    }

    /// "sk-a…xyz", or "…" when nothing is revealed.
    public var masked: String { head + "…" + tail }
}
