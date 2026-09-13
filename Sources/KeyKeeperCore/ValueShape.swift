import Foundation

/// What a value looks like, said in a way that never says what it is.
///
/// KeyKeeper deliberately never shows a secret — not to the caller, not in the approval
/// window. But "you are about to store 412 characters across 5 lines, with Chinese text in
/// it" is not the secret; it is the difference between a key and a paragraph of prose that
/// landed on the clipboard by accident. Every field here is a count or a yes/no.
public struct ValueShape: Equatable, Sendable, Codable {
    public let characters: Int
    /// UTF-8 bytes, which is what storage and every length limit actually count.
    public let bytes: Int
    public let lines: Int
    /// Set when the whole string is valid Base64: how many bytes it decodes to.
    public let base64DecodedBytes: Int?
    /// Set when the whole string is valid hexadecimal: how many bytes it represents.
    public let hexDecodedBytes: Int?
    public let hasWhitespace: Bool
    public let hasNonASCII: Bool
    public let hasControlCharacters: Bool

    public static func of(_ value: String) -> ValueShape {
        let scalars = value.unicodeScalars
        return ValueShape(
            characters: value.count,
            bytes: value.utf8.count,
            lines: value.isEmpty ? 0 : value.components(separatedBy: .newlines).count,
            base64DecodedBytes: decodedBase64Count(value),
            hexDecodedBytes: decodedHexCount(value),
            hasWhitespace: scalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) },
            hasNonASCII: scalars.contains { !$0.isASCII },
            hasControlCharacters: scalars.contains {
                CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
            }
        )
    }

    private static func decodedBase64Count(_ value: String) -> Int? {
        // Foundation accepts stray characters unless told otherwise; require the whole string.
        guard !value.isEmpty, value.count % 4 == 0 else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard let data = Data(base64Encoded: value), !data.isEmpty else { return nil }
        return data.count
    }

    private static func decodedHexCount(_ value: String) -> Int? {
        guard !value.isEmpty, value.count % 2 == 0 else { return nil }
        guard value.unicodeScalars.allSatisfy({ $0.properties.isASCIIHexDigit }) else { return nil }
        return value.count / 2
    }
}

/// What the caller says it expects the value to look like.
///
/// A caller is not trusted with anything by declaring this: the only thing a wrong
/// declaration can do is get the save refused. That makes it safe to accept from any
/// process, and it is the one check that would have caught the 2026-09-13 incident, where
/// a clipboard overwrite put a paragraph of prompt text where an ed25519 key belonged.
public enum ValueExpectation: Equatable, Sendable, Codable {
    case bytes(Int)
    case characters(Int)
    case base64(decodedBytes: Int?)
    case hex(bytes: Int?)

    /// "bytes:64", "chars:40", "base64", "base64:32", "hex:32". Nil for anything else —
    /// an unparseable expectation must refuse the save, never quietly allow it.
    public static func parse(_ raw: String) -> ValueExpectation? {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let keyword = String(parts[0])
        var count: Int?
        if parts.count == 2 {
            guard let parsed = Int(parts[1]), parsed > 0, parsed <= 65_536 else { return nil }
            count = parsed
        }
        switch keyword {
        case "bytes": return count.map { .bytes($0) }
        case "chars", "characters": return count.map { .characters($0) }
        case "base64": return .base64(decodedBytes: count)
        case "hex": return .hex(bytes: count)
        default: return nil
        }
    }

    public func matches(_ shape: ValueShape) -> Bool {
        switch self {
        case .bytes(let count): return shape.bytes == count
        case .characters(let count): return shape.characters == count
        case .base64(let decoded):
            guard let actual = shape.base64DecodedBytes else { return false }
            return decoded.map { $0 == actual } ?? true
        case .hex(let expected):
            guard let actual = shape.hexDecodedBytes else { return false }
            return expected.map { $0 == actual } ?? true
        }
    }
}
