import Foundation
import KeyKeeperCore

/// What kind of thing a stored key is, so lists can show it at a glance.
enum CredentialKind: Equatable {
    /// Ordinary text values (API keys, tokens, URLs).
    case text
    /// A service-account JSON file: contents are never shown, only used through a private file.
    case serviceAccountFile

    init(_ credential: Credential) {
        self = credential.fields.values.contains { $0.fileFormat != nil } ? .serviceAccountFile : .text
    }
}

/// Notes with their web addresses turned into links (yyt: a console URL in the note should
/// open, not sit there as plain text). The text itself is unchanged.
enum NoteText {
    static func attributed(_ note: String) -> AttributedString {
        var result = AttributedString(note)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let whole = NSRange(note.startIndex..., in: note)
        for match in detector.matches(in: note, range: whole) {
            guard let url = match.url, let range = Range(match.range, in: note),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
        }
        return result
    }
}

extension Credential {
    /// Field names for list subtitles, using the display name people gave a field when there is one.
    var fieldSummary: String {
        fields.sorted { $0.key < $1.key }
            .map { $0.value.displayName ?? $0.key }
            .joined(separator: " · ")
    }
}
