import Foundation

/// The last four characters of a stored secret, like the end of a card number: enough to tell
/// two keys apart at a glance, too little to use.
///
/// 用户 2026-11-08 定：列表、详情、编辑页的值显示后 4 位（盘点第三节第 6 条）。Computed from the
/// Keychain item the app already reads without a prompt to see which values exist; never
/// written to metadata, never sent over IPC, so agents and the CLI do not see it.
public enum ValueHint {
    /// Shorter values (passwords, PINs) show no characters at all: four of eight is half of it.
    public static let minimumLength = 12

    public static func suffix(of value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumLength else { return nil }
        return String(trimmed.suffix(4))
    }
}

/// Which stored values exist, plus their last four characters where they are long enough.
public struct CredentialValueOverview: Equatable, Sendable {
    /// credential ID → field names that have a stored value.
    public var names: [String: Set<String>]
    /// credential ID → field name → last four characters.
    public var hints: [String: [String: String]]

    public init(names: [String: Set<String>], hints: [String: [String: String]] = [:]) {
        self.names = names
        self.hints = hints
    }
}
