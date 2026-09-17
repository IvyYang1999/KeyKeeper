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
    /// Error names in a non-OK body that still prove the key is real — Resend answers a
    /// sending-only key (the permission we recommend) with 401 `restricted_api_key`, which is
    /// "valid but not allowed to list", not "wrong key".
    public var validIfBodyContains: [String]
    /// What the request does, for the save prompt ("lists the models this key can use").
    public var description: String

    public init(method: String = "GET", url: String, header: String, valuePrefix: String = "",
                extraHeaders: [String: String] = [:], okStatuses: [Int] = [200], invalidStatuses: [Int] = [401],
                validIfBodyContains: [String] = [], description: String) {
        self.method = method
        self.url = url
        self.header = header
        self.valuePrefix = valuePrefix
        self.extraHeaders = extraHeaders
        self.okStatuses = okStatuses
        self.invalidStatuses = invalidStatuses
        self.validIfBodyContains = validIfBodyContains
        self.description = description
    }

    public var host: String { URL(string: url)?.host ?? url }
}

public enum ProviderFieldKind: String, Codable, Equatable, Sendable {
    /// A token/password stored in the Keychain and injected as text.
    case secretText
    /// A complete credential document stored in the Keychain and materialized as a temporary file.
    case secretFile
    /// A non-secret account/project identifier. It still needs human confirmation before injection.
    case publicText
    /// A signing identity that remains in the macOS Keychain; KeyKeeper stores no private material.
    case localIdentity
}

public struct ProviderFieldTemplate: Codable, Equatable, Sendable {
    public var name: String
    public var label: String
    public var kind: ProviderFieldKind
    public var required: Bool
    public var isPrimary: Bool
    public var fileFormat: CredentialFileFormat?
    public var prefixes: [String]
    public var minChars: Int?
    /// An official full-value format contract. Use only when the provider documents the grammar;
    /// examples and observed lengths are not contracts and must not become write blockers.
    public var regularExpression: String?
    public var help: String
    /// Earlier SDK/client field names for this same value, not additional secrets. Copied into
    /// signed credential metadata only when the person approves creating the credential.
    public var aliases: [String]?

    public init(name: String, label: String, kind: ProviderFieldKind, required: Bool = true,
                isPrimary: Bool = false, fileFormat: CredentialFileFormat? = nil,
                prefixes: [String] = [], minChars: Int? = nil, regularExpression: String? = nil,
                help: String = "", aliases: [String]? = nil) {
        self.name = name
        self.label = label
        self.kind = kind
        self.required = required
        self.isPrimary = isPrimary
        self.fileFormat = fileFormat
        self.prefixes = prefixes
        self.minChars = minChars
        self.regularExpression = regularExpression
        self.help = help
        self.aliases = aliases
    }

    public var environmentName: String? {
        kind == .localIdentity ? nil : EnvironmentVariableName.from(fieldName: name, prefix: "")
    }
    public var isSaveableSecret: Bool { kind == .secretText || kind == .secretFile }

    public var environmentNames: [String] {
        guard let environmentName else { return [] }
        return (aliases ?? []).reduce(into: [environmentName]) { names, alias in
            let name = EnvironmentVariableName.from(fieldName: alias)
            if !names.contains(name) { names.append(name) }
        }
    }

    public func shapeProblem(for value: String, providerName: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixes.isEmpty, !prefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return "\(providerName) \(label) starts with \(prefixes.joined(separator: " or ")); this value does not."
        }
        if let minChars, trimmed.count < minChars {
            return "\(providerName) \(label) is at least \(minChars) characters; this value is \(trimmed.count)."
        }
        if let regularExpression,
           trimmed.range(of: regularExpression, options: .regularExpression) == nil {
            return "\(providerName) \(label) does not match the provider's documented format."
        }
        return nil
    }
}

/// Routing facts for the caller to configure deliberately. These are not probes and are never
/// automatically injected as BASE_URL. Placeholders must be resolved from the provider console.
public struct ProviderEndpoint: Codable, Equatable, Sendable {
    public var protocolName: String
    public var baseURL: String
    public var region: String?
    public init(_ protocolName: String, _ baseURL: String, region: String? = nil) {
        self.protocolName = protocolName; self.baseURL = baseURL; self.region = region
    }
}

/// Where a person who has no account yet can sign up. yyt 2026-09-16: "创建 key 的那个链接，确实
/// 可以放联盟营销的链接" — but a referral link is a sign-up page, useless and confusing to
/// someone already logged in, so it lives next to `createURL`, never replaces it. What each side
/// gets is stated as structured template data, printed by the CLI and shown in the docs, so those
/// facts travel with the link. Nothing else in a template — order, permissions, advice —
/// may depend on this field; a test enforces the ordering.
public struct ProviderSignup: Codable, Equatable, Sendable {
    /// The referral sign-up page; https only.
    public var url: String
    /// What the person gets by signing up through it ("2000 万 tokens"), if anything.
    public var whatYouGet: String?
    /// What KeyKeeper gets ("$5 in credits once you spend $10"), always stated.
    public var whatWeGet: String
    /// An invite code to enter on the form when the provider works that way.
    public var code: String?

    public init(url: String, whatYouGet: String? = nil, whatWeGet: String, code: String? = nil) {
        self.url = url; self.whatYouGet = whatYouGet; self.whatWeGet = whatWeGet; self.code = code
    }
}

public struct ProviderTemplate: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var aliases: [String]
    /// Suggested field name; its environment variable is what the provider's SDKs read.
    public var fieldName: String
    /// Complete v2 bundle contract. `fieldName` remains the primary field for old callers.
    public var fields: [ProviderFieldTemplate]
    /// The official page where the key is created.
    public var createURL: String
    /// Steps only the person can do: login, mfa, billing, org/project choice.
    public var gates: [String]
    public var minimalPermission: String
    /// What a key looks like: one of these prefixes, and a floor on length. Checked before
    /// anything is written. Empty means no prefix rule (GitHub has `ghp_` and `github_pat_`).
    public var prefixes: [String]
    public var minChars: Int?
    /// `true` only when the provider explicitly documents one-time display. `false` means that
    /// one-time display is not confirmed; it must not be presented as a promise of recoverability.
    public var shownOnce: Bool
    public var validation: ProviderValidation?
    public var rotateURL: String?
    /// Where the provider says when the key stops working, if it does at all.
    public var expiryNote: String?
    /// When this template was last checked against the provider's real pages.
    public var verified: String
    public var endpoints: [ProviderEndpoint]?
    public var sources: [String]?
    /// Only for people without an account; see `ProviderSignup`. Nil for most providers.
    public var signup: ProviderSignup?

    public init(id: String, name: String, aliases: [String] = [], fieldName: String,
                fields: [ProviderFieldTemplate]? = nil, createURL: String,
                gates: [String], minimalPermission: String, prefixes: [String] = [], minChars: Int? = nil,
                shownOnce: Bool, validation: ProviderValidation? = nil, rotateURL: String? = nil,
                expiryNote: String? = nil, verified: String,
                endpoints: [ProviderEndpoint]? = nil, sources: [String]? = nil,
                signup: ProviderSignup? = nil) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.fieldName = fieldName
        self.fields = fields ?? [ProviderFieldTemplate(name: fieldName, label: "API key",
            kind: .secretText, isPrimary: true, prefixes: prefixes, minChars: minChars)]
        self.createURL = createURL
        self.gates = gates
        self.minimalPermission = minimalPermission
        self.prefixes = prefixes
        self.minChars = minChars
        self.shownOnce = shownOnce
        self.validation = validation
        self.rotateURL = rotateURL
        self.expiryNote = expiryNote
        self.verified = verified
        self.endpoints = endpoints
        self.sources = sources
        self.signup = signup
    }

    /// The environment variable `keykeeper run` sets for this field (no prefix).
    public var environmentName: String { EnvironmentVariableName.from(fieldName: fieldName, prefix: "") }
    public var primaryField: ProviderFieldTemplate {
        fields.first(where: \.isPrimary) ?? ProviderFieldTemplate(name: fieldName, label: "API key",
            kind: .secretText, isPrimary: true, prefixes: prefixes, minChars: minChars)
    }
    public func field(named name: String) -> ProviderFieldTemplate? {
        fields.first { $0.name == name } ?? fields.first { $0.aliases?.contains(name) == true }
    }

    public var contractProblems: [String] {
        var problems: [String] = []
        if fields.filter(\.isPrimary).count != 1 { problems.append("must have exactly one primary field") }
        if primaryField.name != fieldName { problems.append("primary field must equal fieldName") }
        if Set(fields.map(\.name)).count != fields.count { problems.append("field names must be unique") }
        for field in fields {
            if field.name.isEmpty { problems.append("field name must not be empty") }
            for alias in field.aliases ?? [] {
                if !CredentialNames.isValidFieldName(alias) || EnvironmentVariableName.isReserved(fieldName: alias) {
                    problems.append("\(field.name) has an unsafe alias")
                }
                if fields.contains(where: { $0.name == alias && $0.name != field.name }) {
                    problems.append("\(field.name) alias conflicts with another field")
                }
            }
            if (field.kind == .secretFile) != (field.fileFormat != nil) {
                problems.append("\(field.name) file format does not match its kind")
            }
            if let pattern = field.regularExpression,
               (try? NSRegularExpression(pattern: pattern)) == nil {
                problems.append("\(field.name) regular expression is invalid")
            }
        }
        for endpoint in endpoints ?? [] {
            if !endpoint.baseURL.hasPrefix("https://") || endpoint.protocolName.isEmpty {
                problems.append("endpoint must name a protocol and use HTTPS")
            }
        }
        if let signup {
            if !signup.url.hasPrefix("https://") { problems.append("signup url must use HTTPS") }
            if signup.whatWeGet.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("signup must say what KeyKeeper gets") }
        }
        return problems
    }

    /// Nil when the value looks like this provider's key; otherwise why not (no value inside).
    public func shapeProblem(for value: String) -> String? {
        // Keep the original mutable properties authoritative for source compatibility. Tests,
        // SDK users and older call sites can still copy a template and customize these rules.
        ProviderFieldTemplate(name: fieldName, label: "key", kind: primaryField.kind,
            isPrimary: true, fileFormat: primaryField.fileFormat,
            prefixes: prefixes, minChars: minChars,
            regularExpression: primaryField.regularExpression).shapeProblem(for: value, providerName: name)
    }

    public func shapeProblem(for value: String, fieldName: String) -> String? {
        fieldName == self.fieldName
            ? shapeProblem(for: value)
            : field(named: fieldName)?.shapeProblem(for: value, providerName: name)
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

public struct ProbeReply: Sendable, Equatable {
    public var status: Int
    /// The first few KB of the body, for error names only; never stored, never shown.
    public var body: String
    public init(status: Int, body: String = "") { self.status = status; self.body = body }
}

public protocol ProbeTransport: Sendable {
    /// Sends the request and returns status and body; throws when nothing came back.
    func send(_ request: URLRequest) async throws -> ProbeReply
}

public struct URLSessionProbeTransport: ProbeTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> ProbeReply {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return ProbeReply(status: http.statusCode, body: String(decoding: data.prefix(16_384), as: UTF8.self))
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

    public static func outcome(_ reply: ProbeReply, validation: ProviderValidation) -> CredentialValidation {
        if validation.okStatuses.contains(reply.status) { return .valid }
        if validation.validIfBodyContains.contains(where: { reply.body.contains($0) }) { return .valid }
        if validation.invalidStatuses.contains(reply.status) { return .invalid }
        return .unreachable
    }

    public static func run(_ validation: ProviderValidation, value: String, transport: any ProbeTransport) async -> CredentialValidation {
        guard let request = request(validation, value: value) else { return .skipped }
        do { return outcome(try await transport.send(request), validation: validation) }
        catch { return .unreachable }
    }
}

/// Built into the app and the CLI, so an agent can read them offline (`keykeeper providers`).
public enum ProviderCatalog {
    public static let all: [ProviderTemplate] = ([
        ProviderTemplate(
            id: "openai", name: "OpenAI", aliases: ["gpt", "chatgpt", "openai-api"],
            fieldName: "openai-api-key",
            createURL: "https://platform.openai.com/api-keys",
            gates: ["Log in to platform.openai.com", "Choose the project (keys are per project)", "Billing must be set up before the key can be used"],
            minimalPermission: "Create a key with Restricted permissions: only the capabilities the task needs (usually Model capabilities: Write). Not All.",
            shownOnce: true,
            validation: ProviderValidation(url: "https://api.openai.com/v1/models", header: "Authorization", valuePrefix: "Bearer ",
                                           description: "lists the models this key can use"),
            rotateURL: "https://platform.openai.com/api-keys",
            expiryNote: "OpenAI's public key guide does not promise one universal expiration policy. Record an expiry only when the project console shows one.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "anthropic", name: "Anthropic", aliases: ["claude", "anthropic-api"],
            fieldName: "anthropic-api-key",
            createURL: "https://console.anthropic.com/settings/keys",
            gates: ["Log in to console.anthropic.com", "Choose a single workspace for this project", "Choose the shortest practical expiration", "Billing or credits must be set up before the key can be used"],
            minimalPermission: "Prefer a service-account key in a single dedicated workspace. Multi-workspace keys need an extra workspace header that this template does not guess.",
            prefixes: ["sk-ant-"], shownOnce: true,
            validation: ProviderValidation(url: "https://api.anthropic.com/v1/models", header: "x-api-key",
                                           extraHeaders: ["anthropic-version": "2023-06-01"],
                                           description: "lists the models this key can use"),
            rotateURL: "https://console.anthropic.com/settings/keys",
            expiryNote: "Choose 3 hours, 1/7/30 days, a custom date, or never; prefer the shortest practical value.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "gemini", name: "Google Gemini", aliases: ["google-ai", "google-gemini", "aistudio"],
            fieldName: "gemini-api-key",
            createURL: "https://aistudio.google.com/apikey",
            gates: ["Log in with the Google account", "Accept the terms on first use", "Choose or import a Google Cloud project"],
            minimalPermission: "Create the key restricted to the Gemini API only (the default). Standard unrestricted keys are rejected by Gemini API starting September 2026.",
            shownOnce: false,
            validation: ProviderValidation(url: "https://generativelanguage.googleapis.com/v1beta/models", header: "x-goog-api-key",
                                           invalidStatuses: [400, 401],
                                           description: "lists the models this key can use"),
            rotateURL: "https://aistudio.google.com/apikey",
            expiryNote: "The public Gemini key guide does not promise one universal expiry or recovery policy; review it in Google Cloud.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "supabase", name: "Supabase Management API", aliases: ["supabase-cli", "supabase-access-token"],
            fieldName: "supabase-access-token",
            createURL: "https://supabase.com/dashboard/account/tokens",
            gates: ["Log in to supabase.com", "Name the token", "Pick an expiry"],
            minimalPermission: "This is a Management API personal access token, not a database/runtime key. Prefer a scoped PAT limited to one project and only the permissions needed; classic PATs inherit the account's broad access.",
            prefixes: ["sbp_"], shownOnce: true,
            validation: ProviderValidation(url: "https://api.supabase.com/v1/projects", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "lists the projects this token can see"),
            rotateURL: "https://supabase.com/dashboard/account/tokens",
            expiryNote: "Set the Management API token's expiry when creating it and record that date here.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "vercel", name: "Vercel", aliases: ["vercel-token"],
            fieldName: "vercel-token",
            fields: [
                .init(name: "vercel-token", label: "Access token", kind: .secretText, isPrimary: true),
                .init(name: "vercel-org-id", label: "Team or user ID", kind: .publicText, required: false),
                .init(name: "vercel-project-id", label: "Project ID", kind: .publicText, required: false),
            ],
            createURL: "https://vercel.com/account/tokens",
            gates: ["Log in to vercel.com", "Name the token", "Pick the user or Team scope and expiry", "Record project/team IDs separately when the workflow needs them"],
            minimalPermission: "Vercel tokens are scoped to a user or Team, not one project. Choose the narrowest account or Team and shortest expiry; use the optional IDs to target one project.",
            shownOnce: true,
            validation: ProviderValidation(url: "https://api.vercel.com/v2/user", header: "Authorization", valuePrefix: "Bearer ",
                                           description: "reads the authenticated Vercel identity"),
            rotateURL: "https://vercel.com/account/tokens",
            expiryNote: "Expiry is chosen at creation (1 day to 1 year, or none). A token that leaks to a public repo is revoked automatically.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "github", name: "GitHub", aliases: ["gh", "github-token", "github-pat"],
            fieldName: "github-token",
            createURL: "https://github.com/settings/personal-access-tokens/new",
            gates: ["Log in to github.com (2FA where the organization requires it)", "Choose the resource owner (you or an organization; an organization may have to approve)", "Set the expiry"],
            minimalPermission: "Fine-grained token: Repository access = Only select repositories (the ones the task touches), and only the permissions the task needs (e.g. Contents: Read). Leave everything else at No access. Expiry: 30 days or less.",
            prefixes: ["github_pat_", "ghp_"], shownOnce: true,
            validation: ProviderValidation(url: "https://api.github.com/user", header: "Authorization", valuePrefix: "Bearer ",
                                           extraHeaders: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
                                           description: "reads the account the token belongs to (needs no permissions)"),
            rotateURL: "https://github.com/settings/personal-access-tokens",
            expiryNote: "Fine-grained tokens expire on the date chosen (1–366 days, or never); classic tokens unused for a year are deleted.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "cloudflare", name: "Cloudflare · User API Token", aliases: ["cf", "cloudflare-token", "wrangler"],
            fieldName: "cloudflare-api-token",
            createURL: "https://dash.cloudflare.com/profile/api-tokens",
            gates: ["Log in to dash.cloudflare.com (2FA if enabled)", "Choose Create Token → a template or Create Custom Token", "Pick permissions, the zone/account resources, optionally a TTL"],
            minimalPermission: "Create Custom Token: permissions at Read where possible, Zone Resources = Specific zone (never All zones), and a TTL. Use an account-owned token only if the task needs it (it verifies at a different endpoint).",
            shownOnce: true,
            validation: nil,
            rotateURL: "https://dash.cloudflare.com/profile/api-tokens",
            expiryNote: "No expiry unless a TTL was set at creation; Roll replaces the secret and keeps the permissions.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "stripe", name: "Stripe", aliases: ["stripe-key", "stripe-api-key"],
            fieldName: "stripe-api-key",
            createURL: "https://dashboard.stripe.com/apikeys",
            gates: ["Log in to dashboard.stripe.com", "Choose sandbox (test) or live mode", "Create restricted key: name it and pick per-resource permissions", "A 2FA code is required to create a live key"],
            minimalPermission: "Always a Restricted key (rk_…), never the Secret key (sk_…): set each resource to None except the ones the task needs (Read where Read is enough). Start in sandbox (rk_test_) and only create a live key when the task really goes live. Balance: Read lets KeyKeeper verify it.",
            prefixes: ["rk_live_", "rk_test_", "sk_live_", "sk_test_"], shownOnce: true,
            validation: ProviderValidation(url: "https://api.stripe.com/v1/balance", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "reads the account balance (Balance: Read)"),
            rotateURL: "https://dashboard.stripe.com/apikeys",
            expiryNote: "No automatic expiry. Rotation can give the old value a grace period; some payment and transfer capabilities can be limited after long inactivity.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "resend", name: "Resend", aliases: ["resend-api-key"],
            fieldName: "resend-api-key",
            createURL: "https://resend.com/api-keys",
            gates: ["Log in to resend.com", "Name the key", "Pick the permission and, for sending access, the domain"],
            minimalPermission: "Permission = Sending access, limited to the one domain the task sends from. Full access can manage domains and other keys; do not suggest it.",
            prefixes: ["re_"], shownOnce: true,
            validation: ProviderValidation(url: "https://api.resend.com/domains", header: "Authorization", valuePrefix: "Bearer ",
                                           extraHeaders: ["User-Agent": "KeyKeeper/provider-validation"],
                                           invalidStatuses: [401], validIfBodyContains: ["restricted_api_key"],
                                           description: "lists domains; a sending-only key answers 'restricted', which also proves it is real"),
            rotateURL: "https://resend.com/api-keys",
            expiryNote: "Keys do not expire; Resend suggests removing keys unused for 30 days.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "siliconflow", name: "SiliconFlow · China", aliases: ["硅基流动", "siliconflow-cn"],
            fieldName: "siliconflow-api-key",
            createURL: "https://cloud.siliconflow.cn/account/ak",
            gates: ["Log in with phone or email", "Some models require real-name verification first"],
            minimalPermission: "Keys have no scopes: one key is the whole account. Create a separate key per project so it can be deleted alone.",
            shownOnce: false,
            validation: ProviderValidation(url: "https://api.siliconflow.cn/v1/models", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "lists the models this key can use"),
            rotateURL: "https://cloud.siliconflow.cn/account/ak",
            expiryNote: "The public guide does not promise one universal expiration policy; record a date only when the console shows one.",
            verified: "2026-09-15",
            signup: ProviderSignup(
                url: "https://cloud.siliconflow.cn/i/rYSj1fxJ",
                whatYouGet: "a ¥16 platform-wide coupon after registration and real-name verification",
                whatWeGet: "a ¥16 platform-wide coupon",
                code: "rYSj1fxJ")),
        ProviderTemplate(
            id: "app-store-connect", name: "App Store Connect · Team API Key", aliases: ["asc", "appstoreconnect", "apple-api"],
            fieldName: "private-key",
            fields: [
                .init(name: "private-key", label: "API private key (.p8)", kind: .secretFile,
                      isPrimary: true, fileFormat: .applePrivateKeyP8,
                      help: "The downloaded AuthKey file. Apple shows it once; keep the original."),
                .init(name: "key-id", label: "Key ID", kind: .publicText,
                      help: "The 10-character ID shown next to the key."),
                .init(name: "issuer-id", label: "Issuer ID", kind: .publicText,
                      help: "The issuer UUID shown on the Integrations page for team keys."),
            ],
            createURL: "https://appstoreconnect.apple.com/access/integrations/api",
            gates: ["Sign in to App Store Connect", "An Account Holder or Admin chooses Team Keys and creates the key", "Choose the least privileged role the task needs", "Download the .p8 file immediately; it is shown once"],
            minimalPermission: "Prefer a team key with the narrowest App Store Connect role that can perform the task. Use an individual key only for app and user endpoints; Apple does not allow individual keys for notarytool.",
            shownOnce: true,
            rotateURL: "https://appstoreconnect.apple.com/access/integrations/api",
            expiryNote: "Keys do not expire automatically; revoke them on the Integrations page.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "apple-notary", name: "Apple Notary · App-Specific Password", aliases: ["notarytool", "apple-notarization"],
            fieldName: "apple-app-specific-password",
            fields: [
                .init(name: "apple-app-specific-password", label: "App-specific password", kind: .secretText,
                      isPrimary: true,
                      help: "A dedicated password from account.apple.com, not the Apple Account password."),
                .init(name: "apple-id", label: "Apple Account email", kind: .publicText),
                .init(name: "apple-team-id", label: "Developer Team ID", kind: .publicText),
            ],
            createURL: "https://account.apple.com/account/manage",
            gates: ["Sign in to the Apple Account", "Pass two-factor authentication", "Create a dedicated app-specific password under Sign-In and Security"],
            minimalPermission: "Use a dedicated app-specific password only for notarization. Keep Apple Account email and Team ID as non-secret fields in the same credential.",
            shownOnce: false,
            rotateURL: "https://account.apple.com/account/manage",
            expiryNote: "It remains valid until revoked; changing the Apple Account password revokes all app-specific passwords.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "apns", name: "Apple Push Notification service", aliases: ["apple-push", "push-notifications"],
            fieldName: "private-key",
            fields: [
                .init(name: "private-key", label: "APNs private key (.p8)", kind: .secretFile,
                      isPrimary: true, fileFormat: .applePrivateKeyP8,
                      help: "The downloaded AuthKey file. Apple allows one download."),
                .init(name: "key-id", label: "Key ID", kind: .publicText),
                .init(name: "team-id", label: "Developer Team ID", kind: .publicText),
            ],
            createURL: "https://developer.apple.com/account/resources/authkeys/add",
            gates: ["Sign in to the Apple Developer account", "An Account Holder or Admin creates a key", "Enable only Apple Push Notifications service", "Download the .p8 file immediately"],
            minimalPermission: "Create a key with only Apple Push Notifications service enabled. Use topic restrictions where Apple offers them.",
            shownOnce: true,
            rotateURL: "https://developer.apple.com/account/resources/authkeys/list",
            expiryNote: "Keys do not expire automatically; revoke and replace them from Certificates, Identifiers & Profiles.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "developer-id", name: "Apple Developer ID · Application", aliases: ["codesign", "developer-id-application"],
            fieldName: "signing-identity",
            fields: [
                .init(name: "signing-identity", label: "Developer ID Application identity", kind: .localIdentity,
                      isPrimary: true,
                      help: "The certificate and private key stay in the macOS Keychain. KeyKeeper must never import or export them."),
            ],
            createURL: "https://developer.apple.com/account/resources/certificates/add",
            gates: ["Sign in to the Apple Developer account", "Choose Developer ID Application", "Create the certificate from a CSR whose private key remains in this Mac's Keychain"],
            minimalPermission: "Keep the non-exportable signing private key in the macOS Keychain and refer to the Developer ID Application identity by name. Do not copy it into a text credential.",
            shownOnce: false,
            rotateURL: "https://developer.apple.com/account/resources/certificates/list",
            expiryNote: "Developer ID certificates have an Apple-issued expiration date; replace before expiry.",
            verified: "2026-09-15"),
    ] + AdditionalProviderCatalog.all + GatewayModelProviderCatalog.all
      + CloudModelProviderCatalog.all + RoutingModelProviderCatalog.all
      + ExistingModelProviderContracts.regionalTemplates).map(ExistingModelProviderContracts.enrich)

    /// Existing templates stay resolvable for saved credentials, even when we no longer
    /// recommend the provider to someone creating a new key. Not a security verdict.
    public static let legacyOnlyIDs: Set<String> = [
        "compshare-modelverse-cn", "compshare-modelverse-global", "compshare-agent-plan",
        "ccsub", "micu-claude", "micu-codex", "rightcode-codex", "cubence",
        "crazyrouter", "dmxapi-cn", "dmxapi-global", "dmxapi-ssvip", "amux",
        "cherryin", "pipellm", "relaxycode", "therouter",
    ]
    public static let discoverable: [ProviderTemplate] = all.filter { !legacyOnlyIDs.contains($0.id) }

    public static func find(_ idOrAlias: String) -> ProviderTemplate? {
        let needle = idOrAlias.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == needle || $0.aliases.contains { $0.lowercased() == needle } }
    }
}
