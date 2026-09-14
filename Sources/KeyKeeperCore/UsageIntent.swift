import Foundation

// What an agent says it needs a credential for, and whether that adds up.
//
// yyt 2026-09-14: an agent creating an entry now picks the protection, the caller, the duration.
// It can overstate what it needs. Its statement becomes a structured record (UsageIntent), a
// rule check compares the request against it (IntentRules), and — optionally — another model,
// not the one asking, gives an opinion (ModelReviewer). None of them decide; the person does,
// with the disagreement in front of them.

/// How long a caller asks to be approved for.
public enum RequestedDuration: String, Codable, Sendable, CaseIterable {
    case once
    /// While the asking process runs (its terminal session when it has one). `session` and `1h`
    /// are older spellings of roughly the same wish and are folded into it by the prompt.
    case thisRun = "run"
    case session, oneHour = "1h", always

    public var rank: Int {
        switch self {
        case .once: return 0
        case .thisRun, .session: return 1
        case .oneHour: return 2
        case .always: return 3
        }
    }

    /// The three answers the prompt offers.
    public var folded: RequestedDuration {
        switch self {
        case .once: return .once
        case .thisRun, .session, .oneHour: return .thisRun
        case .always: return .always
        }
    }
}

/// The caller's declared use of a credential. Its words, folded to printable lines and capped;
/// never verified. Set when the credential is created (with the person's approval) or by the
/// person in the app — the promptless `edit` path cannot touch it, because later audits measure
/// actual use against it.
public struct UsageIntent: Codable, Equatable, Sendable {
    public enum Frequency: String, Codable, Sendable, CaseIterable {
        case once, occasional, scheduled
    }

    public var purpose: String
    /// Who is expected to use it: "the nightly cron on this Mac", "Codex when I ask".
    public var expectedCaller: String?
    public var frequency: Frequency
    /// Needs to work with nobody at the Mac.
    public var background: Bool
    public var declaredBy: String?
    public var declaredAt: Date?

    public static let purposeLimit = 200

    public init(purpose: String, expectedCaller: String? = nil, frequency: Frequency,
                background: Bool, declaredBy: String? = nil, declaredAt: Date? = nil) {
        self.purpose = purpose
        self.expectedCaller = expectedCaller
        self.frequency = frequency
        self.background = background
        self.declaredBy = declaredBy
        self.declaredAt = declaredAt
    }

    /// Hostile text, like the stated reason: one line each, capped. Nil when no purpose is left.
    public func sanitized() -> UsageIntent? {
        let purpose = CallerStatedReason.printableLine(self.purpose, limit: Self.purposeLimit)
        guard !purpose.isEmpty else { return nil }
        var copy = self
        copy.purpose = purpose
        copy.expectedCaller = expectedCaller.map { CallerStatedReason.printableLine($0, limit: 80) }.flatMap { $0.isEmpty ? nil : $0 }
        copy.declaredBy = declaredBy.map { CallerStatedReason.printableLine($0, limit: 80) }
        return copy
    }
}

/// One thing the rules noticed. The app puts words to each.
public enum IntentFinding: String, Codable, Sendable, CaseIterable {
    /// Wants to run unattended, but says it is a one-off (or says nothing).
    case backgroundForOneOff
    /// Wants "always", but nothing in the declaration is recurring or unattended.
    case alwaysWithoutRecurringUse
    /// The credential's name says production/root/admin/signing; wants background use anyway.
    case sensitiveCredentialBackground
    /// Unattended use with no expiry date recorded.
    case noExpiryForBackground
    /// Asked for more than "once" without ever declaring what for.
    case noIntentDeclared
}

/// What the rules think of a request: the smallest thing that still fits the declaration.
public struct IntentReview: Equatable, Sendable {
    public enum Verdict: String, Sendable { case fine, inflated }
    public var verdict: Verdict
    public var findings: [IntentFinding]
    public var suggestedSecurity: SecurityLevel?
    public var suggestedDuration: RequestedDuration?

    public init(verdict: Verdict, findings: [IntentFinding], suggestedSecurity: SecurityLevel?, suggestedDuration: RequestedDuration?) {
        self.verdict = verdict
        self.findings = findings
        self.suggestedSecurity = suggestedSecurity
        self.suggestedDuration = suggestedDuration
    }
}

/// Everything a review looks at. Nothing in here is a secret value.
public struct IntentReviewInput: Equatable, Sendable {
    public var credentialId: String
    public var credentialLabel: String
    public var fieldNames: [String]
    public var callerName: String
    public var callerTier: String
    public var reason: String?
    public var command: String?
    public var intent: UsageIntent?
    public var expires: String?
    public var requestedSecurity: SecurityLevel?
    public var requestedDuration: RequestedDuration?
    /// "12 reads in the last day, last approval 3 days ago" — whatever the app can say.
    public var history: String?

    public init(credentialId: String, credentialLabel: String, fieldNames: [String] = [], callerName: String,
                callerTier: String = "", reason: String? = nil, command: String? = nil, intent: UsageIntent? = nil,
                expires: String? = nil, requestedSecurity: SecurityLevel? = nil, requestedDuration: RequestedDuration? = nil,
                history: String? = nil) {
        self.credentialId = credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.callerName = callerName
        self.callerTier = callerTier
        self.reason = reason
        self.command = command
        self.intent = intent
        self.expires = expires
        self.requestedSecurity = requestedSecurity
        self.requestedDuration = requestedDuration
        self.history = history
    }
}

/// Deterministic, offline, testable. Catches the common overstatements; says nothing it cannot know.
public enum IntentRules {
    static let sensitiveWords = ["prod", "production", "root", "admin", "master", "signing", "notary", "billing", "payment", "deploy"]

    public static func looksSensitive(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return sensitiveWords.contains { lowered.contains($0) }
    }

    public static func review(_ input: IntentReviewInput) -> IntentReview {
        var findings: [IntentFinding] = []
        var security: SecurityLevel?
        var duration: RequestedDuration?
        let intent = input.intent
        let recurring = intent.map { $0.frequency != .once } ?? false
        let unattended = intent?.background ?? false

        if input.requestedSecurity == .standard {
            if intent == nil || intent?.frequency == .once {
                findings.append(.backgroundForOneOff); security = .strict
            }
            if looksSensitive(input.credentialId) || looksSensitive(input.credentialLabel) {
                findings.append(.sensitiveCredentialBackground); security = .strict
            }
            if input.expires == nil, !findings.contains(.backgroundForOneOff) {
                findings.append(.noExpiryForBackground)
            }
        }
        if input.requestedDuration == .always, !(recurring && unattended) {
            findings.append(.alwaysWithoutRecurringUse)
            duration = recurring ? .thisRun : .once
        }
        if intent == nil, (input.requestedSecurity == .standard || (input.requestedDuration?.rank ?? 0) > RequestedDuration.once.rank),
           !findings.contains(.backgroundForOneOff) {
            findings.append(.noIntentDeclared)
        }
        let inflated = findings.contains { [.backgroundForOneOff, .alwaysWithoutRecurringUse, .sensitiveCredentialBackground].contains($0) }
        return IntentReview(verdict: inflated ? .inflated : .fine, findings: findings,
                            suggestedSecurity: security, suggestedDuration: duration)
    }
}
