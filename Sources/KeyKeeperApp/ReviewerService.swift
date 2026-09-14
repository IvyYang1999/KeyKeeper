import Foundation
import KeyKeeperCore

/// Asks a second model what it thinks of a request, when the person has turned that on.
///
/// The model's key is itself a KeyKeeper credential (`keykeeper-reviewer` / `api-key` by
/// default), read by the app for its own use — no approval, no audit entry, never handed to a
/// caller. Off by default. Its answer is advice: the prompt shows it next to the rules and the
/// buttons stay the person's. A slow or failed answer falls back to the rules alone.
@MainActor
final class ReviewerService {
    static let shared = ReviewerService()

    static let enabledKey = "reviewerEnabled"
    static let credentialKey = "reviewerCredentialId"
    static let defaultCredentialId = "keykeeper-reviewer"
    static let fieldName = "api-key"
    static let timeout: TimeInterval = 15

    enum Outcome: Equatable {
        case disabled
        case opinion(ReviewerOpinion)
        case unavailable(String)
    }

    var defaults: UserDefaults = .standard
    /// The app's own read of a credential value, injected so tests never touch the Keychain.
    var retrieve: (String, String) throws -> String = { _, _ in throw KeychainError.notFound }
    var transport: any ReviewTransport = URLSessionReviewTransport()

    var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var credentialId: String {
        get {
            let stored = defaults.string(forKey: Self.credentialKey)?.trimmingCharacters(in: .whitespaces) ?? ""
            return stored.isEmpty ? Self.defaultCredentialId : stored
        }
        set { defaults.set(newValue, forKey: Self.credentialKey) }
    }

    func review(_ input: IntentReviewInput) async -> Outcome {
        guard isEnabled else { return .disabled }
        let key: String
        do { key = try retrieve(credentialId, Self.fieldName) } catch {
            return .unavailable(L("No key found at \(credentialId) · \(Self.fieldName). Save one there to turn the reviewer on."))
        }
        let reviewer = ModelReviewer(apiKey: key, transport: transport)
        do {
            return .opinion(try await Self.withTimeout(Self.timeout) { try await reviewer.review(input) })
        } catch is CancellationError {
            return .unavailable(L("The reviewer did not answer in time."))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    /// One line for the prompt: "necessity 2/5 · smaller scope would do — <comment>".
    static func line(for opinion: ReviewerOpinion) -> String {
        var parts = [L("necessity \(opinion.necessity)/5")]
        parts.append(opinion.minimalScope ? L("scope is the smallest that works") : L("a smaller scope would do"))
        if let duration = opinion.suggestedDuration { parts.append(RequestReview.durationName(duration)) }
        let head = parts.joined(separator: " · ")
        return opinion.comment.isEmpty ? head : "\(head) — \(opinion.comment)"
    }
}
