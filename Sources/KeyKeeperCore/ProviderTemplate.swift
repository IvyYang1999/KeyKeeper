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
                extraHeaders: [String: String] = [:], okStatuses: [Int] = [200], invalidStatuses: [Int] = [401, 403],
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
    public var help: String

    public init(name: String, label: String, kind: ProviderFieldKind, required: Bool = true,
                isPrimary: Bool = false, fileFormat: CredentialFileFormat? = nil,
                prefixes: [String] = [], minChars: Int? = nil, help: String = "") {
        self.name = name
        self.label = label
        self.kind = kind
        self.required = required
        self.isPrimary = isPrimary
        self.fileFormat = fileFormat
        self.prefixes = prefixes
        self.minChars = minChars
        self.help = help
    }

    public var environmentName: String? {
        kind == .localIdentity ? nil : EnvironmentVariableName.from(fieldName: name, prefix: "")
    }
    public var isSaveableSecret: Bool { kind == .secretText || kind == .secretFile }

    public func shapeProblem(for value: String, providerName: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefixes.isEmpty, !prefixes.contains(where: { trimmed.hasPrefix($0) }) {
            return "\(providerName) \(label) starts with \(prefixes.joined(separator: " or ")); this value does not."
        }
        if let minChars, trimmed.count < minChars {
            return "\(providerName) \(label) is at least \(minChars) characters; this value is \(trimmed.count)."
        }
        return nil
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
    /// The provider shows the key once; copying it right away matters.
    public var shownOnce: Bool
    public var validation: ProviderValidation?
    public var rotateURL: String?
    /// Where the provider says when the key stops working, if it does at all.
    public var expiryNote: String?
    /// When this template was last checked against the provider's real pages.
    public var verified: String

    public init(id: String, name: String, aliases: [String] = [], fieldName: String,
                fields: [ProviderFieldTemplate]? = nil, createURL: String,
                gates: [String], minimalPermission: String, prefixes: [String] = [], minChars: Int? = nil,
                shownOnce: Bool, validation: ProviderValidation? = nil, rotateURL: String? = nil,
                expiryNote: String? = nil, verified: String) {
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
    }

    /// The environment variable `keykeeper run` sets for this field (no prefix).
    public var environmentName: String { EnvironmentVariableName.from(fieldName: fieldName, prefix: "") }
    public var primaryField: ProviderFieldTemplate {
        fields.first(where: \.isPrimary) ?? ProviderFieldTemplate(name: fieldName, label: "API key",
            kind: .secretText, isPrimary: true, prefixes: prefixes, minChars: minChars)
    }
    public func field(named name: String) -> ProviderFieldTemplate? { fields.first { $0.name == name } }

    public var contractProblems: [String] {
        var problems: [String] = []
        if fields.filter(\.isPrimary).count != 1 { problems.append("must have exactly one primary field") }
        if primaryField.name != fieldName { problems.append("primary field must equal fieldName") }
        if Set(fields.map(\.name)).count != fields.count { problems.append("field names must be unique") }
        for field in fields {
            if field.name.isEmpty { problems.append("field name must not be empty") }
            if (field.kind == .secretFile) != (field.fileFormat != nil) {
                problems.append("\(field.name) file format does not match its kind")
            }
        }
        return problems
    }

    /// Nil when the value looks like this provider's key; otherwise why not (no value inside).
    public func shapeProblem(for value: String) -> String? {
        // Keep the original mutable properties authoritative for source compatibility. Tests,
        // SDK users and older call sites can still copy a template and customize these rules.
        ProviderFieldTemplate(name: fieldName, label: "key", kind: primaryField.kind,
            isPrimary: true, fileFormat: primaryField.fileFormat,
            prefixes: prefixes, minChars: minChars).shapeProblem(for: value, providerName: name)
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
    public static let all: [ProviderTemplate] = [
        ProviderTemplate(
            id: "openai", name: "OpenAI", aliases: ["gpt", "chatgpt", "openai-api"],
            fieldName: "openai-api-key",
            createURL: "https://platform.openai.com/api-keys",
            gates: ["Log in to platform.openai.com", "Choose the project (keys are per project)", "Billing must be set up before the key can be used"],
            minimalPermission: "Create a key with Restricted permissions: only the capabilities the task needs (usually Model capabilities: Write). Not All.",
            prefixes: ["sk-"], minChars: 40, shownOnce: true,
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
            prefixes: ["sk-ant-"], minChars: 60, shownOnce: true,
            validation: ProviderValidation(url: "https://api.anthropic.com/v1/models", header: "x-api-key",
                                           extraHeaders: ["anthropic-version": "2023-06-01"],
                                           description: "lists the models this key can use"),
            rotateURL: "https://console.anthropic.com/settings/keys",
            expiryNote: "Keys do not expire unless revoked.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "gemini", name: "Google Gemini", aliases: ["google-ai", "google-gemini", "aistudio"],
            fieldName: "gemini-api-key",
            createURL: "https://aistudio.google.com/apikey",
            gates: ["Log in with the Google account", "Accept the terms on first use", "Choose or import a Google Cloud project"],
            minimalPermission: "Create the key restricted to the Gemini API only (the default). Standard unrestricted keys are being rejected by Gemini from late 2026.",
            prefixes: ["AIza"], minChars: 39, shownOnce: true,
            validation: ProviderValidation(url: "https://generativelanguage.googleapis.com/v1beta/models", header: "x-goog-api-key",
                                           invalidStatuses: [400, 401, 403],
                                           description: "lists the models this key can use"),
            rotateURL: "https://aistudio.google.com/apikey",
            expiryNote: "Keys do not expire; a deleted key can be restored for 30 days.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "supabase", name: "Supabase", aliases: ["supabase-cli", "supabase-access-token"],
            fieldName: "supabase-access-token",
            createURL: "https://supabase.com/dashboard/account/tokens",
            gates: ["Log in to supabase.com", "Name the token", "Pick an expiry"],
            minimalPermission: "Prefer a scoped personal access token limited to the one project and only the read/read-write permissions the task needs. Scoped PATs are still rolling out; if only classic tokens are available, they carry the account's full power, so use a short expiry. For an app's database access use the project's publishable/secret API keys instead.",
            prefixes: ["sbp_"], minChars: 20, shownOnce: true,
            validation: ProviderValidation(url: "https://api.supabase.com/v1/projects", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "lists the projects this token can see"),
            rotateURL: "https://supabase.com/dashboard/account/tokens",
            expiryNote: "Set an expiry when creating it; project API keys never expire.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "vercel", name: "Vercel", aliases: ["vercel-token"],
            fieldName: "vercel-token",
            createURL: "https://vercel.com/account/tokens",
            gates: ["Log in to vercel.com", "Name the token", "Pick the scope and the expiry (some teams require 2FA)"],
            minimalPermission: "Scope: the single project when the task is about one project; otherwise the team. Not Full Account. Expiration: the shortest that fits (7 or 30 days), not No Expiration.",
            prefixes: ["vcp_"], minChars: 28, shownOnce: true,
            validation: ProviderValidation(url: "https://api.vercel.com/v9/projects", header: "Authorization", valuePrefix: "Bearer ",
                                           description: "lists the projects this token can see"),
            rotateURL: "https://vercel.com/account/tokens",
            expiryNote: "Expiry is chosen at creation (1 day to 1 year, or none). A token that leaks to a public repo is revoked automatically.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "github", name: "GitHub", aliases: ["gh", "github-token", "github-pat"],
            fieldName: "github-token",
            createURL: "https://github.com/settings/personal-access-tokens/new",
            gates: ["Log in to github.com (2FA where the organization requires it)", "Choose the resource owner (you or an organization; an organization may have to approve)", "Set the expiry"],
            minimalPermission: "Fine-grained token: Repository access = Only select repositories (the ones the task touches), and only the permissions the task needs (e.g. Contents: Read). Leave everything else at No access. Expiry: 30 days or less.",
            prefixes: ["github_pat_", "ghp_"], minChars: 40, shownOnce: true,
            validation: ProviderValidation(url: "https://api.github.com/user", header: "Authorization", valuePrefix: "Bearer ",
                                           extraHeaders: ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"],
                                           description: "reads the account the token belongs to (needs no permissions)"),
            rotateURL: "https://github.com/settings/personal-access-tokens",
            expiryNote: "Fine-grained tokens expire on the date chosen (1–366 days, or never); classic tokens unused for a year are deleted.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "cloudflare", name: "Cloudflare", aliases: ["cf", "cloudflare-token", "wrangler"],
            fieldName: "cloudflare-api-token",
            createURL: "https://dash.cloudflare.com/profile/api-tokens",
            gates: ["Log in to dash.cloudflare.com (2FA if enabled)", "Choose Create Token → a template or Create Custom Token", "Pick permissions, the zone/account resources, optionally a TTL"],
            minimalPermission: "Create Custom Token: permissions at Read where possible, Zone Resources = Specific zone (never All zones), and a TTL. Use an account-owned token only if the task needs it (it verifies at a different endpoint).",
            prefixes: [], minChars: 40, shownOnce: true,
            validation: ProviderValidation(url: "https://api.cloudflare.com/client/v4/user/tokens/verify", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [400, 401, 403],
                                           description: "asks Cloudflare whether this user token is active"),
            rotateURL: "https://dash.cloudflare.com/profile/api-tokens",
            expiryNote: "No expiry unless a TTL was set at creation; Roll replaces the secret and keeps the permissions.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "stripe", name: "Stripe", aliases: ["stripe-key", "stripe-api-key"],
            fieldName: "stripe-api-key",
            createURL: "https://dashboard.stripe.com/apikeys",
            gates: ["Log in to dashboard.stripe.com", "Choose sandbox (test) or live mode", "Create restricted key: name it and pick per-resource permissions", "A 2FA code is required to create a live key"],
            minimalPermission: "Always a Restricted key (rk_…), never the Secret key (sk_…): set each resource to None except the ones the task needs (Read where Read is enough). Start in sandbox (rk_test_) and only create a live key when the task really goes live. Balance: Read lets KeyKeeper verify it.",
            prefixes: ["rk_live_", "rk_test_", "sk_live_", "sk_test_"], minChars: 32, shownOnce: true,
            validation: ProviderValidation(url: "https://api.stripe.com/v1/balance", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "reads the account balance (Balance: Read)"),
            rotateURL: "https://dashboard.stripe.com/apikeys",
            expiryNote: "No expiry; Rotate key gives the old value up to 7 days of grace. A key unused for 180 days gets restricted.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "resend", name: "Resend", aliases: ["resend-api-key"],
            fieldName: "resend-api-key",
            createURL: "https://resend.com/api-keys",
            gates: ["Log in to resend.com", "Name the key", "Pick the permission and, for sending access, the domain"],
            minimalPermission: "Permission = Sending access, limited to the one domain the task sends from. Full access can manage domains and other keys; do not suggest it.",
            prefixes: ["re_"], minChars: 30, shownOnce: true,
            validation: ProviderValidation(url: "https://api.resend.com/domains", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401, 403], validIfBodyContains: ["restricted_api_key"],
                                           description: "lists domains; a sending-only key answers 'restricted', which also proves it is real"),
            rotateURL: "https://resend.com/api-keys",
            expiryNote: "Keys do not expire; Resend suggests removing keys unused for 30 days.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "siliconflow", name: "SiliconFlow", aliases: ["硅基流动", "siliconflow-cn"],
            fieldName: "siliconflow-api-key",
            createURL: "https://cloud.siliconflow.cn/account/ak",
            gates: ["Log in with phone or email", "Some models require real-name verification first"],
            minimalPermission: "Keys have no scopes: one key is the whole account. Create a separate key per project so it can be deleted alone.",
            prefixes: ["sk-"], minChars: 40, shownOnce: false,
            validation: ProviderValidation(url: "https://api.siliconflow.cn/v1/models", header: "Authorization", valuePrefix: "Bearer ",
                                           invalidStatuses: [401],
                                           description: "lists the models this key can use"),
            rotateURL: "https://cloud.siliconflow.cn/account/ak",
            expiryNote: "No expiry setting; delete and recreate to rotate.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "app-store-connect", name: "App Store Connect", aliases: ["asc", "appstoreconnect", "apple-api"],
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
            id: "apple-notary", name: "Apple Notary", aliases: ["notarytool", "apple-notarization"],
            fieldName: "apple-app-specific-password",
            fields: [
                .init(name: "apple-app-specific-password", label: "App-specific password", kind: .secretText,
                      isPrimary: true, minChars: 19,
                      help: "A dedicated password from account.apple.com, not the Apple Account password."),
                .init(name: "apple-id", label: "Apple Account email", kind: .publicText),
                .init(name: "apple-team-id", label: "Developer Team ID", kind: .publicText),
            ],
            createURL: "https://account.apple.com/account/manage",
            gates: ["Sign in to the Apple Account", "Pass two-factor authentication", "Create a dedicated app-specific password under Sign-In and Security"],
            minimalPermission: "Use a dedicated app-specific password only for notarization. Keep Apple Account email and Team ID as non-secret fields in the same credential.",
            minChars: 19, shownOnce: true,
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
            id: "developer-id", name: "Apple Developer ID", aliases: ["codesign", "developer-id-application"],
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
    ] + AdditionalProviderCatalog.all

    public static func find(_ idOrAlias: String) -> ProviderTemplate? {
        let needle = idOrAlias.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.id == needle || $0.aliases.contains(needle) }
    }
}
