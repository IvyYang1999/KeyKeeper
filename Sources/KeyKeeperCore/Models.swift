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
