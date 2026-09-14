import Foundation
import KeyKeeperCore

/// What the person sees between the request and the buttons: what the agent asks, what the rules
/// think of it, and (if turned on) what a second model thinks. yyt 2026-09-14: the agent picks
/// the protection, the caller and the duration when it creates an entry; something independent
/// should say whether that is more than it needs. None of this decides — it is put next to the
/// buttons, and the buttons still belong to the person.
struct RequestReview: Equatable {
    let input: IntentReviewInput
    let rules: IntentReview

    static func make(prompt: AuthorizationPrompt, credential: Credential?, approvals: ApprovalStore?) -> RequestReview {
        let caller = prompt.callerIdentity
        let assurance = caller.map { CallerAssurance.of($0.subject) } ?? .unverified
        var history: String?
        if let approvals, let count = try? approvals.approvals(forCredential: prompt.credentialId).count {
            history = count == 0 ? "no approvals on record for this credential" : "\(count) approval(s) on record for this credential"
        }
        let input = IntentReviewInput(
            credentialId: prompt.credentialId,
            credentialLabel: prompt.credentialLabel,
            fieldNames: prompt.fieldNames,
            callerName: TrustPromptModel.sanitizedCaller(caller?.displayName ?? "unknown"),
            callerTier: assurance.tierName,
            reason: prompt.statedReason?.text,
            command: prompt.commandSummary,
            intent: credential?.intent,
            expires: credential?.expires,
            requestedSecurity: nil,          // the protection was settled when the entry was created
            requestedDuration: prompt.requestedDuration,
            history: history)
        return RequestReview(input: input, rules: IntentRules.review(input))
    }

    /// The agent's own wish, as one line for the prompt. Nil when it said nothing.
    var agentAsksLine: String? {
        guard let duration = input.requestedDuration else { return nil }
        return Self.durationName(duration)
    }

    var hasContent: Bool { agentAsksLine != nil || !rules.findings.isEmpty || input.intent != nil }

    /// The rules' verdict for the prompt, as a short sentence; nil when nothing was found.
    var keykeeperSuggestsLine: String? {
        guard let finding = rules.findings.first else { return nil }
        var parts: [String] = []
        if let duration = rules.suggestedDuration { parts.append(Self.durationName(duration)) }
        if let security = rules.suggestedSecurity { parts.append(SecurityLevelPresentation.badge(security)) }
        let text = Self.findingText(finding)
        return parts.isEmpty ? text : "\(parts.joined(separator: " · ")) — \(text)"
    }

    /// The declared use, as the person recorded it when the entry was created.
    var intentLine: String? {
        guard let intent = input.intent else { return nil }
        var tail = [Self.frequencyName(intent.frequency)]
        if intent.background { tail.append(L("unattended")) }
        if let caller = intent.expectedCaller { tail.append(caller) }
        return "\(intent.purpose) (\(tail.joined(separator: " · ")))"
    }

    static func durationName(_ duration: RequestedDuration) -> String {
        switch duration {
        case .once: return L("Just this once")
        case .thisRun: return L("While it runs")
        case .session: return L("This terminal session")
        case .oneHour: return L("1 hour")
        case .always: return L("Don't ask again")
        }
    }

    static func frequencyName(_ frequency: UsageIntent.Frequency) -> String {
        switch frequency {
        case .once: return L("one-off")
        case .occasional: return L("now and then")
        case .scheduled: return L("on a schedule")
        }
    }

    static func findingText(_ finding: IntentFinding) -> String {
        switch finding {
        case .backgroundForOneOff: return L("a one-off use does not need to run unattended")
        case .alwaysWithoutRecurringUse: return L("nothing declared here recurs unattended, so \u{201C}always\u{201D} is more than it needs")
        case .sensitiveCredentialBackground: return L("this looks like a production or admin key; keep it behind a prompt")
        case .noExpiryForBackground: return L("unattended use with no expiry date on record")
        case .noIntentDeclared: return L("nobody declared what this key is for")
        }
    }
}

extension CallerAssurance {
    /// The tier as a plain word for the reviewer model and the audit log.
    var tierName: String {
        switch self {
        case .signed: return "signed"
        case .unsigned: return "unsigned"
        case .unverified: return "unverified"
        case .relayed: return "relayed"
        }
    }
}

extension AuthorizationPrompt {
    var requestedDuration: RequestedDuration? {
        switch self {
        case .strict(let request): return request.requestedDuration
        case .service(let request): return request.request.requestedDuration
        }
    }

    /// The command the caller reports it is running. Its own words: one printable line, capped.
    var commandSummary: String? {
        let raw: String?
        switch self {
        case .strict(let request): raw = request.commandSummary
        case .service(let request): raw = request.request.commandSummary
        }
        guard let raw else { return nil }
        let line = CallerStatedReason.printableLine(raw, limit: 200)
        return line.isEmpty ? nil : line
    }
}
