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

    public init(value: String? = nil, secret: Bool, fileFormat: CredentialFileFormat? = nil,
                displayName: String? = nil, aliases: [String]? = nil) {
        self.value = value
        self.secret = secret
        self.fileFormat = fileFormat
        self.displayName = displayName
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

    public init(label: String, notes: String, links: [String],
                fields: [String: CredentialField], security: SecurityLevel,
                created: String, updated: String, aliases: [String]? = nil, expires: String? = nil) {
        self.label = label
        self.notes = notes
        self.links = links
        self.fields = fields
        self.security = security
        self.created = created
        self.updated = updated
        self.aliases = aliases
        self.expires = expires
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

