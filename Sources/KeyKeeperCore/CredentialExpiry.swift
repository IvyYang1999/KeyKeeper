import Foundation

/// The day a key stops working at its provider, as the person or an agent recorded it.
///
/// A day, not a timestamp: providers say "expires Dec 31", and that is what people copy. It is the
/// last day the key is expected to work. KeyKeeper only ever says so — a recorded date can be wrong,
/// and blocking or deleting a key on a guess would be worse than a warning.
public enum CredentialExpiry {
    public enum Status: Equatable, Sendable {
        case valid(daysLeft: Int)
        /// Within `soonWithinDays`; 0 means today is the last day.
        case expiresSoon(daysLeft: Int)
        case expired(daysAgo: Int)
    }

    public static let soonWithinDays = 14

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    /// A real calendar day written as YYYY-MM-DD, or nil. "2026-02-30" and "2026-2-3" are not dates.
    public static func normalize(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = formatter().date(from: trimmed),
              formatter().string(from: date) == trimmed else { return nil }
        return trimmed
    }

    public static func date(from value: String) -> Date? {
        normalize(value).flatMap { formatter().date(from: $0) }
    }

    public static func string(from date: Date) -> String {
        formatter().string(from: date)
    }

    public static func status(of expires: String?, today: Date = Date(), calendar: Calendar = .current) -> Status? {
        guard let expires, let day = date(from: expires) else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: today),
                                           to: calendar.startOfDay(for: day)).day ?? 0
        if days < 0 { return .expired(daysAgo: -days) }
        if days <= soonWithinDays { return .expiresSoon(daysLeft: days) }
        return .valid(daysLeft: days)
    }

    /// One line on stderr for whoever runs the key, only once the recorded day has passed.
    public static func warning(credentialId: String, expires: String?, today: Date = Date()) -> String? {
        guard let expires, case .expired = status(of: expires, today: today) else { return nil }
        return "keykeeper: '\(credentialId)' was recorded as expiring on \(expires). KeyKeeper still passes it along; if the provider rejects it, the key needs replacing — tell the user."
    }

    /// For `keykeeper list`.
    public static func summary(_ expires: String?, today: Date = Date()) -> String? {
        guard let expires, let status = status(of: expires, today: today) else { return nil }
        func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }
        switch status {
        case .expired(let daysAgo): return "\(expires) (expired \(days(daysAgo)) ago)"
        case .expiresSoon(0): return "\(expires) (last day today)"
        case .expiresSoon(let daysLeft): return "\(expires) (in \(days(daysLeft)))"
        case .valid: return expires
        }
    }
}
