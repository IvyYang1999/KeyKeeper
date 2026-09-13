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

    public init(label: String, notes: String, links: [String],
                fields: [String: CredentialField], security: SecurityLevel,
                created: String, updated: String, aliases: [String]? = nil) {
        self.label = label
        self.notes = notes
        self.links = links
        self.fields = fields
        self.security = security
        self.created = created
        self.updated = updated
        self.aliases = aliases
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

    public init(version: Int = 1, storeInitialized: Bool? = nil, credentials: [String: Credential] = [:]) {
        self.version = version
        self.storeInitialized = storeInitialized
        self.credentials = credentials
    }
}

// MARK: - Grant System

public enum GrantDuration: Codable, Sendable, Equatable {
    case once
    case session(String)  // session ID
    case timed(Date)      // expiration date
    case always

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "once": self = .once
        case "session":
            let id = try container.decode(String.self, forKey: .value)
            self = .session(id)
        case "timed":
            let date = try container.decode(Date.self, forKey: .value)
            self = .timed(date)
        case "always": self = .always
        default: throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown grant duration: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .once:
            try container.encode("once", forKey: .type)
        case .session(let id):
            try container.encode("session", forKey: .type)
            try container.encode(id, forKey: .value)
        case .timed(let date):
            try container.encode("timed", forKey: .type)
            try container.encode(date, forKey: .value)
        case .always:
            try container.encode("always", forKey: .type)
        }
    }
}

public struct Grant: Codable, Sendable, Identifiable {
    public var id: String
    public var credentialId: String
    public var sessionId: String?
    public var duration: GrantDuration
    public var createdAt: Date
    /// For .once grants: marked true after first use
    public var consumed: Bool
    /// Which program this was granted to.
    ///
    /// 【曾经的 bug】yyt 2026-09-13：「我点击 always 的原因是我不想再给我的 Agents 们授权
    /// 了，而不是本机任意一个进程都可以。」Grants used to carry no caller at all, so "Always"
    /// really did mean every process on the Mac — while the button just said "Always". Nil means
    /// a grant issued before this existed; it still works, and gets pinned to whoever uses it
    /// next rather than being torn up under people who were relying on it.
    public var subjectFingerprint: String?
    public var subjectDisplayName: String?

    public init(id: String = UUID().uuidString, credentialId: String,
                sessionId: String? = nil, duration: GrantDuration,
                createdAt: Date = Date(), consumed: Bool = false,
                subjectFingerprint: String? = nil, subjectDisplayName: String? = nil) {
        self.id = id
        self.credentialId = credentialId
        self.sessionId = sessionId
        self.duration = duration
        self.createdAt = createdAt
        self.consumed = consumed
        self.subjectFingerprint = subjectFingerprint
        self.subjectDisplayName = subjectDisplayName
    }
}

public struct GrantFile: Codable, Sendable {
    public var version: Int
    public var grants: [Grant]

    public init(version: Int = 1, grants: [Grant] = []) {
        self.version = version
        self.grants = grants
    }
}
