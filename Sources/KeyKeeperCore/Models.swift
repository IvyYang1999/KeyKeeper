import Foundation

public enum SecurityLevel: String, Codable, Sendable {
    case standard
    case strict
}

/// Durable, local-only shape rules for one secret field. These are deliberately smaller than a
/// regular-expression language: an untrusted caller may ask for a stricter save, but must not be
/// able to hand the App a catastrophic regex that burns CPU. The fragments are public format
/// constants (for example `GOCSPX-`), never secret material.
public struct CredentialFieldValidation: Codable, Equatable, Sendable {
    public var rejectURL: Bool
    public var prefixes: [String]
    public var suffixes: [String]

    public init(rejectURL: Bool = false, prefixes: [String] = [], suffixes: [String] = []) {
        self.rejectURL = rejectURL
        self.prefixes = prefixes
        self.suffixes = suffixes
    }

    private enum CodingKeys: String, CodingKey { case rejectURL, prefixes, suffixes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rejectURL = try c.decodeIfPresent(Bool.self, forKey: .rejectURL) ?? false
        prefixes = try c.decodeIfPresent([String].self, forKey: .prefixes) ?? []
        suffixes = try c.decodeIfPresent([String].self, forKey: .suffixes) ?? []
    }

    public var isEmpty: Bool { !rejectURL && prefixes.isEmpty && suffixes.isEmpty }

    /// Validate and canonicalize a rule declaration before it crosses a trust boundary or lands
    /// in metadata. Only short printable ASCII fragments are allowed because metadata is visible.
    public func validated() throws -> Self {
        func checked(_ fragments: [String]) throws -> [String] {
            guard fragments.count <= 8 else { throw CredentialFieldValidationError.invalidDeclaration }
            var unique: [String] = []
            for fragment in fragments {
                guard !fragment.isEmpty, fragment.utf8.count <= 64,
                      fragment.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) })
                else { throw CredentialFieldValidationError.invalidDeclaration }
                if !unique.contains(fragment) { unique.append(fragment) }
            }
            return unique
        }
        return Self(rejectURL: rejectURL, prefixes: try checked(prefixes), suffixes: try checked(suffixes))
    }

    /// Combine an already approved rule with a new request without ever broadening what may pass.
    /// Two prefix (or suffix) alternative sets are intersected; incompatible sets are refused.
    public func tightening(with other: Self) throws -> Self {
        let left = try validated(), right = try other.validated()
        func intersect(_ old: [String], _ new: [String], compatible: (String, String) -> String?) throws -> [String] {
            if old.isEmpty { return new }
            if new.isEmpty { return old }
            var result: [String] = []
            for a in old {
                for b in new {
                    if let stricter = compatible(a, b), !result.contains(stricter) { result.append(stricter) }
                }
            }
            guard !result.isEmpty else { throw CredentialFieldValidationError.wouldBroadenOrConflict }
            return result
        }
        let narrowedPrefixes = try intersect(left.prefixes, right.prefixes) { a, b in
            if a.hasPrefix(b) { return a }
            if b.hasPrefix(a) { return b }
            return nil
        }
        let narrowedSuffixes = try intersect(left.suffixes, right.suffixes) { a, b in
            if a.hasSuffix(b) { return a }
            if b.hasSuffix(a) { return b }
            return nil
        }
        return Self(rejectURL: left.rejectURL || right.rejectURL,
                    prefixes: narrowedPrefixes, suffixes: narrowedSuffixes)
    }

    /// Nil means the value satisfies every rule. The reason names only the failed rule; it never
    /// includes any part of the candidate value or the configured public fragment.
    public func problem(for value: String) -> String? {
        if rejectURL {
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
                return "This field rejects web URLs. Copy the credential value, not the receiver or console URL."
            }
        }
        if !prefixes.isEmpty, !prefixes.contains(where: value.hasPrefix) {
            return "The value does not start with this field's configured prefix."
        }
        if !suffixes.isEmpty, !suffixes.contains(where: value.hasSuffix) {
            return "The value does not end with this field's configured suffix."
        }
        return nil
    }

    public var summary: String {
        var rules: [String] = []
        if rejectURL { rules.append("reject web URLs") }
        if !prefixes.isEmpty { rules.append("prefix " + prefixes.joined(separator: " or ")) }
        if !suffixes.isEmpty { rules.append("suffix " + suffixes.joined(separator: " or ")) }
        return rules.joined(separator: ", ")
    }
}

public enum CredentialFieldValidationError: Error, LocalizedError {
    case invalidDeclaration, wouldBroadenOrConflict
    public var errorDescription: String? {
        switch self {
        case .invalidDeclaration:
            return "Persistent validation fragments must be 1–64 printable ASCII characters without spaces; at most 8 prefixes or suffixes."
        case .wouldBroadenOrConflict:
            return "New persistent validation must narrow the field's existing prefixes and suffixes, not replace them with unrelated alternatives."
        }
    }
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
    /// Shape rules approved with this field. Every later safe restore or replacement reuses them;
    /// nil means an older field has no durable custom rule.
    public var validation: CredentialFieldValidation?

    public init(value: String? = nil, secret: Bool, fileFormat: CredentialFileFormat? = nil,
                displayName: String? = nil, aliases: [String]? = nil, setByCaller: String? = nil,
                validation: CredentialFieldValidation? = nil) {
        self.value = value
        self.secret = secret
        self.fileFormat = fileFormat
        self.displayName = displayName
        self.setByCaller = setByCaller
        self.aliases = aliases
        self.validation = validation
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
