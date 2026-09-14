import Foundation
import KeyKeeperCore

/// Asks a second model what it thinks of a request, when the person has turned that on.
///
/// The model's key is typed in by the person and kept in the app-owned Keychain document with
/// the approvals — never a KeyKeeper credential, never handed to a caller. Off by default. Its answer is advice: the prompt shows it next to the rules and the
/// buttons stay the person's. A slow or failed answer falls back to the rules alone.
/// Its settings sit in the app-owned Keychain item with the approvals — in UserDefaults any local
/// process could point the app at a real key and its own server. yyt 2026-09-14: any provider — a base URL, the API it speaks, and a model picked from what
/// that service lists for the key.
@MainActor
final class ReviewerService {
    static let shared = ReviewerService()

    static let timeout: TimeInterval = 15

    enum Outcome: Equatable {
        case disabled
        case opinion(ReviewerOpinion)
        case unavailable(String)
    }

    /// Settings live in the app-owned approvals Keychain item, never in UserDefaults: they name
    /// which credential's value leaves the machine and where to.
    let store: ApprovalStore
    var transport: any ReviewTransport = URLSessionReviewTransport()

    init(store: ApprovalStore = .shared) { self.store = store }

    private var settings: ReviewerSettings {
        get { (try? store.reviewerSettings()) ?? ReviewerSettings() }
        set { try? store.setReviewerSettings(newValue) }
    }

    var isEnabled: Bool {
        get { settings.enabled }
        set { settings.enabled = newValue }
    }

    /// Typed by the person in Settings; stored in the Keychain document; never shown back.
    var apiKey: String {
        get { settings.apiKey }
        set { settings.apiKey = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var hasKey: Bool { !apiKey.isEmpty }

    var baseURLText: String {
        get { let url = settings.baseURL.trimmingCharacters(in: .whitespaces); return url.isEmpty ? ReviewerEndpoint.defaultBaseURL : url }
        set { settings.baseURL = newValue }
    }

    /// Nil means "guess from the host".
    var apiOverride: ReviewerEndpoint.API? {
        get { settings.api }
        set { settings.api = newValue }
    }

    var model: String {
        get { let model = settings.model.trimmingCharacters(in: .whitespaces); return model.isEmpty ? ReviewerEndpoint.defaultModel : model }
        set { settings.model = newValue }
    }

    /// Nil when the base URL is not a URL.
    var endpoint: ReviewerEndpoint? {
        guard let url = ReviewerEndpoint.parseBaseURL(baseURLText) else { return nil }
        return ReviewerEndpoint(baseURL: url, api: apiOverride ?? ReviewerEndpoint.guessAPI(for: url), model: model)
    }

    private func key() -> String? { hasKey ? apiKey : nil }

    var missingKeyMessage: String { L("No API key entered for the reviewer.") }

    func review(_ input: IntentReviewInput) async -> Outcome {
        guard isEnabled else { return .disabled }
        guard let endpoint else { return .unavailable(L("The reviewer's base URL is not a URL.")) }
        guard let key = key() else { return .unavailable(missingKeyMessage) }
        let reviewer = ModelReviewer(apiKey: key, endpoint: endpoint, transport: transport)
        do {
            return .opinion(try await Self.withTimeout(Self.timeout) { try await reviewer.review(input) })
        } catch is CancellationError {
            return .unavailable(L("The reviewer did not answer in time."))
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    /// What the service at the base URL offers this key, for the settings picker.
    func listModels() async -> Result<[String], Error> {
        guard let endpoint else { return .failure(ReviewerListError(L("The reviewer's base URL is not a URL."))) }
        guard let key = key() else { return .failure(ReviewerListError(missingKeyMessage)) }
        let transport = self.transport
        do {
            return .success(try await Self.withTimeout(Self.timeout) {
                try await ModelReviewer.listModels(apiKey: key, endpoint: endpoint, transport: transport)
            })
        } catch is CancellationError {
            return .failure(ReviewerListError(L("The service did not answer in time.")))
        } catch {
            return .failure(error)
        }
    }

    struct ReviewerListError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
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
