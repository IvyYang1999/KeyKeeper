import Foundation

// yyt 2026-09-15: "服务商模板这个思路绝了". What an agent needs to get a key it does not have yet —
// where the official page is, which gates only the person can pass, what the smallest useful
// permission is, what the key looks like — and how KeyKeeper itself can check that the saved
// key works, with a read-only request the agent never sees the value of.

/// How KeyKeeper checks a freshly saved key against the provider, without side effects. The
/// value travels in one header to one fixed https URL; never in the URL, never in a body.
public struct ProviderValidation: Codable, Equatable, Sendable {
    public var method: String
    public var url: String
    /// Header carrying the key ("Authorization", "x-api-key").
    public var header: String
    /// Text put before the value in that header ("Bearer ").
    public var valuePrefix: String
    public var extraHeaders: [String: String]
    public var okStatuses: [Int]
    /// Statuses that mean "the key itself is wrong" (as opposed to unreachable/rate-limited).
    public var invalidStatuses: [Int]
    /// What the request does, for the save prompt ("lists the models this key can use").
    public var description: String

    public init(method: String = "GET", url: String, header: String, valuePrefix: String = "",
                extraHeaders: [String: String] = [:], okStatuses: [Int] = [200], invalidStatuses: [Int] = [401, 403],
                description: String) {
        self.method = method
        self.url = url
        self.header = header
        self.valuePrefix = valuePrefix
        self.extraHeaders = extraHeaders
        self.okStatuses = okStatuses
        self.invalidStatuses = invalidStatuses
        self.description = description
    }

    public var host: String { URL(string: url)?.host ?? url }
}

public struct ProviderTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var aliases: [String]
    /// Suggested field name; its environment variable is what the provider's SDKs read.
    public var fieldName: String
    /// The official page where the key is created.
    public var createURL: String
    /// Steps only the person can do: login, mfa, billing, org/project choice.
    public var gates: [String]
    public var minimalPermission: String
    /// What a key looks like: fixed prefix and a floor on length. Checked before anything is written.
    public var prefix: String?
    public var minChars: Int?
    /// The provider shows the key once; copying it right away matters.
    public var shownOnce: Bool
    public var validation: ProviderValidation?
    public var rotateURL: String?
    /// Where the provider says when the key stops working, if it does at all.
    public var expiryNote: String?
    /// When this template was last checked against the provider's real pages.
    public var verified: String

    public init(id: String, name: String, aliases: [String] = [], fieldName: String, createURL: String,
                gates: [String], minimalPermission: String, prefix: String? = nil, minChars: Int? = nil,
                shownOnce: Bool, validation: ProviderValidation? = nil, rotateURL: String? = nil,
                expiryNote: String? = nil, verified: String) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.fieldName = fieldName
        self.createURL = createURL
        self.gates = gates
        self.minimalPermission = minimalPermission
        self.prefix = prefix
        self.minChars = minChars
        self.shownOnce = shownOnce
        self.validation = validation
        self.rotateURL = rotateURL
        self.expiryNote = expiryNote
        self.verified = verified
    }

    /// The environment variable `keykeeper run` sets for this field (no prefix).
    public var environmentName: String { EnvironmentVariableName.from(fieldName: fieldName, prefix: "") }

    /// Nil when the value looks like this provider's key; otherwise why not (no value inside).
    public func shapeProblem(for value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prefix, !trimmed.hasPrefix(prefix) {
            return "\(name) keys start with \(prefix); this value does not."
        }
        if let minChars, trimmed.count < minChars {
            return "\(name) keys are at least \(minChars) characters; this value is \(trimmed.count)."
        }
        return nil
    }
}

/// The outcome of checking a saved key with the provider. Reported to the caller; never a value.
public enum CredentialValidation: String, Codable, Sendable, Equatable {
    /// The provider accepted the key.
    case valid
    /// The provider rejected the key itself.
    case invalid
    /// No answer, or an answer that says nothing about the key (rate limit, outage).
    case unreachable
    /// No template, or the template has no validation.
    case skipped
}

public protocol ProbeTransport: Sendable {
    /// Sends the request and returns the HTTP status; throws when nothing came back.
    func status(for request: URLRequest) async throws -> Int
}

public struct URLSessionProbeTransport: ProbeTransport {
    public init() {}
    public func status(for request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http.statusCode
    }
}

public enum ProviderProbe {
    public static let timeout: TimeInterval = 10

    /// The value goes into one header of a fixed https request. Nil when the template's URL is
    /// not https — a probe over plain http would be a leak.
    public static func request(_ validation: ProviderValidation, value: String) -> URLRequest? {
        guard let url = URL(string: validation.url), url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = validation.method
        request.timeoutInterval = timeout
        request.httpBody = nil
        request.setValue(validation.valuePrefix + value, forHTTPHeaderField: validation.header)
        for (name, header) in validation.extraHeaders { request.setValue(header, forHTTPHeaderField: name) }
        return request
    }

    public static func outcome(status: Int, validation: ProviderValidation) -> CredentialValidation {
        if validation.okStatuses.contains(status) { return .valid }
        if validation.invalidStatuses.contains(status) { return .invalid }
        return .unreachable
    }

    public static func run(_ validation: ProviderValidation, value: String, transport: any ProbeTransport) async -> CredentialValidation {
        guard let request = request(validation, value: value) else { return .skipped }
        do { return outcome(status: try await transport.status(for: request), validation: validation) }
        catch { return .unreachable }
    }
}

/// Built into the app and the CLI, so an agent can read them offline (`keykeeper providers`).
public enum ProviderCatalog {
    public static let all: [ProviderTemplate] = [
        ProviderTemplate(
            id: "openai", name: "OpenAI", aliases: ["gpt", "chatgpt", "openai-api"],
            fieldName: "openai-api-key",
            createURL: "https://platform.openai.com/api-keys",
            gates: ["Log in to platform.openai.com", "Choose the project (keys are per project)", "Billing must be set up before the key can be used"],
            minimalPermission: "Create a key with Restricted permissions: only the capabilities the task needs (usually Model capabilities: Write). Not All.",
            prefix: "sk-", minChars: 40, shownOnce: true,
            validation: ProviderValidation(url: "https://api.openai.com/v1/models", header: "Authorization", valuePrefix: "Bearer ",
                                           description: "lists the models this key can use"),
            rotateURL: "https://platform.openai.com/api-keys",
            expiryNote: "Keys do not expire unless revoked.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "anthropic", name: "Anthropic", aliases: ["claude", "anthropic-api"],
            fieldName: "anthropic-api-key",
            createURL: "https://console.anthropic.com/settings/keys",
            gates: ["Log in to console.anthropic.com", "Choose the workspace", "Billing or credits must be set up before the key can be used"],
            minimalPermission: "Create the key in a workspace that only holds this project; there are no per-key scopes, so the workspace is the boundary.",
            prefix: "sk-ant-", minChars: 60, shownOnce: true,
            validation: ProviderValidation(url: "https://api.anthropic.com/v1/models", header: "x-api-key",
                                           extraHeaders: ["anthropic-version": "2023-06-01"],
                                           description: "lists the models this key can use"),
            rotateURL: "https://console.anthropic.com/settings/keys",
            expiryNote: "Keys do not expire unless revoked.",
            verified: "2026-09-15"),
    ]

    public static func find(_ idOrAlias: String) -> ProviderTemplate? {
        let needle = idOrAlias.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == needle || $0.aliases.contains(needle) }
    }
}
