import Foundation

public enum SecurityLevel: String, Codable, Sendable {
    case standard
    case strict
}

public struct CredentialField: Codable, Sendable {
    public var value: String?
    public var secret: Bool

    public init(value: String? = nil, secret: Bool) {
        self.value = value
        self.secret = secret
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

    public init(label: String, notes: String, links: [String],
                fields: [String: CredentialField], security: SecurityLevel,
                created: String, updated: String) {
        self.label = label
        self.notes = notes
        self.links = links
        self.fields = fields
        self.security = security
        self.created = created
        self.updated = updated
    }
}

public struct MetaFile: Codable, Sendable {
    public var version: Int
    public var credentials: [String: Credential]

    public init(version: Int = 1, credentials: [String: Credential] = [:]) {
        self.version = version
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

    public init(id: String = UUID().uuidString, credentialId: String,
                sessionId: String? = nil, duration: GrantDuration,
                createdAt: Date = Date(), consumed: Bool = false) {
        self.id = id
        self.credentialId = credentialId
        self.sessionId = sessionId
        self.duration = duration
        self.createdAt = createdAt
        self.consumed = consumed
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
