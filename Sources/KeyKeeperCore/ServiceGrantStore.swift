import Foundation

public enum ServiceAuthorizationMode: String, Codable, Sendable, Equatable {
    case permissive
    case enforced
}

public enum ServiceGrantDuration: Codable, Sendable, Equatable {
    case once
    case timed(Date)
    case always

    private enum CodingKeys: String, CodingKey {
        case type, value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "once":
            self = .once
        case "timed":
            self = .timed(try container.decode(Date.self, forKey: .value))
        case "always":
            self = .always
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown service grant duration: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .once:
            try container.encode("once", forKey: .type)
        case .timed(let date):
            try container.encode("timed", forKey: .type)
            try container.encode(date, forKey: .value)
        case .always:
            try container.encode("always", forKey: .type)
        }
    }
}

public struct ServiceGrant: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var credentialId: String
    public var subjectFingerprint: String
    public var subjectDisplayName: String
    public var fields: [String]
    public var duration: ServiceGrantDuration
    public var createdAt: Date
    public var lastUsedAt: Date?

    public init(id: String = UUID().uuidString,
                credentialId: String,
                subjectFingerprint: String,
                subjectDisplayName: String,
                fields: [String],
                duration: ServiceGrantDuration,
                createdAt: Date = Date(),
                lastUsedAt: Date? = nil) {
        self.id = id
        self.credentialId = credentialId
        self.subjectFingerprint = subjectFingerprint
        self.subjectDisplayName = subjectDisplayName
        self.fields = Array(Set(fields)).sorted()
        self.duration = duration
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

public struct ServiceAuditEvent: Codable, Sendable, Equatable {
    public var timestamp: Date
    public var credentialId: String
    public var fieldName: String
    public var subjectFingerprint: String
    public var subjectDisplayName: String
    public var mode: ServiceAuthorizationMode
    public var decision: String

    public init(timestamp: Date = Date(),
                credentialId: String,
                fieldName: String,
                subjectFingerprint: String,
                subjectDisplayName: String,
                mode: ServiceAuthorizationMode,
                decision: String) {
        self.timestamp = timestamp
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.subjectFingerprint = subjectFingerprint
        self.subjectDisplayName = subjectDisplayName
        self.mode = mode
        self.decision = decision
    }
}

public struct ServiceGrantFile: Codable, Sendable, Equatable {
    public var version: Int
    public var mode: ServiceAuthorizationMode
    public var grants: [ServiceGrant]
    public var auditEvents: [ServiceAuditEvent]

    public init(version: Int = 1,
                mode: ServiceAuthorizationMode = .permissive,
                grants: [ServiceGrant] = [],
                auditEvents: [ServiceAuditEvent] = []) {
        self.version = version
        self.mode = mode
        self.grants = grants
        self.auditEvents = auditEvents
    }
}

public final class ServiceGrantStore: Sendable {
    private let fileURL: URL
    private static let maxAuditEvents = 500

    public init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("service-grants.json")
    }

    public static var `default`: ServiceGrantStore {
        let dir = KeyKeeperPaths.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ServiceGrantStore(directory: dir)
    }

    public func authorizationMode() throws -> ServiceAuthorizationMode {
        try load().mode
    }

    public func setAuthorizationMode(_ mode: ServiceAuthorizationMode) throws {
        try withFileLock { file in
            file.mode = mode
        }
    }

    public func findValidGrant(credentialId: String,
                               subjectFingerprint: String,
                               fieldName: String,
                               now: Date = Date()) throws -> ServiceGrant? {
        let file = try load()
        return file.grants.first { grant in
            grant.credentialId == credentialId
                && grant.subjectFingerprint == subjectFingerprint
                && grant.fields.contains(fieldName)
                && isValid(grant: grant, now: now)
        }
    }

    public func addGrant(_ grant: ServiceGrant) throws {
        try withFileLock { file in
            file.grants.removeAll {
                $0.credentialId == grant.credentialId
                    && $0.subjectFingerprint == grant.subjectFingerprint
                    && Set($0.fields) == Set(grant.fields)
            }
            file.grants.append(grant)
        }
    }

    public func noteSuccessfulUse(grantId: String, fieldName: String, at date: Date = Date()) throws {
        try withFileLock { file in
            guard let index = file.grants.firstIndex(where: { $0.id == grantId }) else { return }
            file.grants[index].lastUsedAt = date
            if case .once = file.grants[index].duration {
                file.grants[index].fields.removeAll { $0 == fieldName }
                if file.grants[index].fields.isEmpty {
                    file.grants.remove(at: index)
                }
            }
        }
    }

    public func revokeGrant(id: String) throws {
        try withFileLock { file in
            file.grants.removeAll { $0.id == id }
        }
    }

    public func grants(credentialId: String? = nil) throws -> [ServiceGrant] {
        let file = try load()
        let now = Date()
        return file.grants.filter { grant in
            (credentialId == nil || grant.credentialId == credentialId)
                && isValid(grant: grant, now: now)
        }
    }

    public func recordAuditEvent(_ event: ServiceAuditEvent) throws {
        try withFileLock { file in
            file.auditEvents.append(event)
            if file.auditEvents.count > Self.maxAuditEvents {
                file.auditEvents.removeFirst(file.auditEvents.count - Self.maxAuditEvents)
            }
        }
    }

    public func auditEvents() throws -> [ServiceAuditEvent] {
        try load().auditEvents
    }

    public func pruneExpired() throws {
        let now = Date()
        try withFileLock { file in
            file.grants.removeAll { !isValid(grant: $0, now: now) }
        }
    }

    private func load() throws -> ServiceGrantFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ServiceGrantFile()
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ServiceGrantFile.self, from: data)
    }

    private func save(_ file: ServiceGrantFile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)
        try data.write(to: fileURL, options: .atomic)
    }

    private func withFileLock<T>(_ body: (inout ServiceGrantFile) throws -> T) throws -> T {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try save(ServiceGrantFile())
        }

        let fd = open(fileURL.path, O_RDWR)
        guard fd >= 0 else {
            throw ServiceGrantStoreError.lockFailed
        }
        defer { close(fd) }

        guard flock(fd, LOCK_EX) == 0 else {
            throw ServiceGrantStoreError.lockFailed
        }
        defer { flock(fd, LOCK_UN) }

        var file = try load()
        let result = try body(&file)
        try save(file)
        return result
    }

    private func isValid(grant: ServiceGrant, now: Date) -> Bool {
        switch grant.duration {
        case .once:
            return !grant.fields.isEmpty
        case .timed(let expiration):
            return now < expiration
        case .always:
            return true
        }
    }
}

public enum ServiceGrantStoreError: Error, LocalizedError {
    case lockFailed

    public var errorDescription: String? {
        switch self {
        case .lockFailed:
            return "Failed to acquire service grants file lock"
        }
    }
}

public enum ServiceAuthorizationDecision: Equatable {
    case allowed(ServiceGrant?)
    case promptRequired
}

public enum ServiceAuthorizationPolicy {
    public static func decisionForValueAccess(credential: Credential,
                                              credentialId: String,
                                              fieldName: String,
                                              caller: CallerIdentity,
                                              serviceGrantStore: ServiceGrantStore,
                                              now: Date = Date()) throws -> ServiceAuthorizationDecision {
        guard credential.security == .standard else {
            return .allowed(nil)
        }

        if let grant = try serviceGrantStore.findValidGrant(
            credentialId: credentialId,
            subjectFingerprint: caller.subjectFingerprint,
            fieldName: fieldName,
            now: now
        ) {
            return .allowed(grant)
        }

        let mode = try serviceGrantStore.authorizationMode()
        try serviceGrantStore.recordAuditEvent(ServiceAuditEvent(
            credentialId: credentialId,
            fieldName: fieldName,
            subjectFingerprint: caller.subjectFingerprint,
            subjectDisplayName: caller.displayName,
            mode: mode,
            decision: mode == .permissive ? "allowed_without_grant" : "prompt_required"
        ))

        switch mode {
        case .permissive:
            return .allowed(nil)
        case .enforced:
            return .promptRequired
        }
    }
}
