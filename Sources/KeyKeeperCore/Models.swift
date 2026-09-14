import Foundation

public enum SecurityLevel: String, Codable, Sendable {
    case standard
    case strict
}

public struct CredentialField: Codable, Sendable {
    public var value: String?
    public var secret: Bool
    /// Nil means the original text-field contract. File contents never live in metadata.
    public var fileFormat: CredentialFileFormat?
    /// What the person called this field ("API Key "), free text for people and agents.
    /// The dictionary key is the machine name that becomes the environment variable.
    public var displayName: String?
    /// Earlier machine names. They keep working forever: `run` still injects their variables.
    public var aliases: [String]?
    /// Who wrote this plain value over the socket, when nobody has confirmed it since. A plain
    /// field becomes an environment variable, and `*_BASE_URL`, `HTTPS_PROXY` or `SSL_CERT_FILE`
    /// next to a key sends the key wherever the value says — so a value a caller set without a
    /// prompt is not injected until the person has seen it in the app. 【独立审计 2026-09-14】
    public var setByCaller: String?

    public init(value: String? = nil, secret: Bool, fileFormat: CredentialFileFormat? = nil,
                displayName: String? = nil, aliases: [String]? = nil, setByCaller: String? = nil) {
        self.value = value
        self.secret = secret
        self.fileFormat = fileFormat
        self.displayName = displayName
        self.setByCaller = setByCaller
        self.aliases = aliases
    }
}

public struct Credential: Codable, Sendable {
    public var label: String
    public var notes: String
    public var links: [String]
    public var fields: [String: CredentialField]
    public var security: SecurityLevel
    public var created: String
    public var updated: String
    /// Earlier group IDs (the `-c` name). They keep resolving to this credential forever.
    public var aliases: [String]?
    /// The last day the key is expected to work at its provider, YYYY-MM-DD (see CredentialExpiry).
    /// Nil when nobody recorded one — and then it is left out of the file entirely, so metadata
    /// signed before this existed still verifies.
    public var expires: String?
    /// What the creator said it is for (see UsageIntent). Nil when nobody declared one.
    public var intent: UsageIntent?
    /// True: values only ever go into a child process's environment through `keykeeper run`;
    /// `get`, the SDKs and anything speaking the socket directly are refused. yyt 2026-09-14:
    /// `get` to a pipe puts the value straight into an agent's context. Credentials an agent
    /// creates start this way; the person can open one up in the app. Nil (older data) = false.
    public var injectOnly: Bool?
    /// The provider template this credential was created from (`ProviderCatalog`), if any.
    public var provider: String?

    public var isInjectOnly: Bool { injectOnly ?? false }

    /// Plain fields a caller wrote that nobody has confirmed: field name → who wrote it.
    public var unconfirmedPlainFields: [String: String] {
        fields.reduce(into: [:]) { result, entry in
            if !entry.value.secret, let caller = entry.value.setByCaller { result[entry.key] = caller }
        }
    }

    public init(label: String, notes: String, links: [String],
                fields: [String: CredentialField], security: SecurityLevel,
                created: String, updated: String, aliases: [String]? = nil, expires: String? = nil,
                intent: UsageIntent? = nil, injectOnly: Bool? = nil, provider: String? = nil) {
        self.label = label
        self.notes = notes
        self.links = links
        self.fields = fields
        self.security = security
        self.created = created
        self.updated = updated
        self.aliases = aliases
        self.expires = expires
        self.intent = intent
        self.injectOnly = injectOnly
        self.provider = provider
    }
}

public struct MetaFile: Codable, Sendable {
    public var version: Int
    /// Set the first time a Keychain store is written on this machine, and never cleared.
    ///
    /// The "never recreate an empty store" guard used to ask "does metadata still name a
    /// secret?". Once fields can move between secret and plain, a vault can hold no secrets at
    /// all for a while — and the guard would switch itself off exactly when a missing Keychain
    /// item should have stopped everything (2026-09: 49 credentials lost their values that way).
    public var storeInitialized: Bool?
    public var credentials: [String: Credential]
    /// HMAC over everything else, keyed from the Keychain. See `MetaIntegrity`.
    ///
    /// Absent in files written before 0.3.4, and absent is not the same as wrong: an older file
    /// is adopted, a changed one is refused.
    public var integrity: String?

    public init(version: Int = 1, storeInitialized: Bool? = nil,
                credentials: [String: Credential] = [:], integrity: String? = nil) {
        self.version = version
        self.storeInitialized = storeInitialized
        self.credentials = credentials
        self.integrity = integrity
    }
}

// MARK: - Grant System

