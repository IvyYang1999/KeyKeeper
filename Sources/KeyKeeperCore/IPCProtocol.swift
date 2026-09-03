import Foundation

// MARK: - Socket Path

public enum IPCConstants {
    public static var socketPath: String {
        "/tmp/keykeeper-\(NSUserName()).sock"
    }

    /// Maximum time (seconds) CLI waits for authorization response
    public static let authTimeout: TimeInterval = 120

    /// Maximum time (seconds) the app waits for a client to send a complete request.
    public static let serverReadTimeout: TimeInterval = 5

    /// Maximum time (seconds) the app lets a Keychain read occupy a value request.
    public static let keychainTimeout: TimeInterval = 10
}

public enum KeychainReadTimeoutPolicy {
    public static func timeout(for security: SecurityLevel) -> TimeInterval {
        switch security {
        case .strict:
            // A legacy Keychain item can require an interactive macOS authorization prompt.
            // Give the user the same window as KeyKeeper's own authorization flow.
            return IPCConstants.authTimeout
        case .standard:
            return IPCConstants.keychainTimeout
        }
    }
}

// MARK: - Request / Response Envelopes

public enum IPCRequest: Codable, Sendable {
    case auth(AuthRequest)
    case value(ValueRequest)
    case serviceRequests(ServiceRequestsListRequest)
    case sessionControl(SessionControlRequest)

    private enum CodingKeys: String, CodingKey { case type, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auth(let r):
            try c.encode("auth", forKey: .type)
            try c.encode(r, forKey: .data)
        case .value(let r):
            try c.encode("value", forKey: .type)
            try c.encode(r, forKey: .data)
        case .serviceRequests(let r):
            try c.encode("serviceRequests", forKey: .type)
            try c.encode(r, forKey: .data)
        case .sessionControl(let r):
            try c.encode("sessionControl", forKey: .type)
            try c.encode(r, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "auth":  self = .auth(try c.decode(AuthRequest.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueRequest.self, forKey: .data))
        case "serviceRequests": self = .serviceRequests(try c.decode(ServiceRequestsListRequest.self, forKey: .data))
        case "sessionControl": self = .sessionControl(try c.decode(SessionControlRequest.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown IPC request type")
        }
    }
}

public enum IPCResponse: Codable, Sendable {
    case auth(AuthResponse)
    case value(ValueResponse)
    case serviceRequests(ServiceRequestsListResponse)
    case sessionControl(SessionControlResponse)

    private enum CodingKeys: String, CodingKey { case type, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auth(let r):
            try c.encode("auth", forKey: .type)
            try c.encode(r, forKey: .data)
        case .value(let r):
            try c.encode("value", forKey: .type)
            try c.encode(r, forKey: .data)
        case .serviceRequests(let r):
            try c.encode("serviceRequests", forKey: .type)
            try c.encode(r, forKey: .data)
        case .sessionControl(let r):
            try c.encode("sessionControl", forKey: .type)
            try c.encode(r, forKey: .data)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "auth":  self = .auth(try c.decode(AuthResponse.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueResponse.self, forKey: .data))
        case "serviceRequests": self = .serviceRequests(try c.decode(ServiceRequestsListResponse.self, forKey: .data))
        case "sessionControl": self = .sessionControl(try c.decode(SessionControlResponse.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown IPC response type")
        }
    }
}

// MARK: - Messages

public enum SessionControlAction: String, Codable, Sendable, Equatable {
    case unlock
    case lock
    case status
}

public struct SessionControlRequest: Codable, Sendable, Equatable {
    public var action: SessionControlAction
    public var passphrase: String?

    public init(action: SessionControlAction, passphrase: String? = nil) {
        self.action = action
        self.passphrase = passphrase
    }
}

public enum SessionControlState: String, Codable, Sendable, Equatable {
    case locked
    case unlockedManual
    case unlockedUntil
}

public enum SessionControlErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest
    case unlockFailed
}

public struct SessionControlResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var state: SessionControlState?
    public var expiresAt: Date?
    public var error: String?
    public var errorCode: SessionControlErrorCode?

    public init(
        success: Bool,
        state: SessionControlState? = nil,
        expiresAt: Date? = nil,
        error: String? = nil,
        errorCode: SessionControlErrorCode? = nil
    ) {
        self.success = success
        self.state = state
        self.expiresAt = expiresAt
        self.error = error
        self.errorCode = errorCode
    }
}

public struct ValueRequest: Codable, Sendable {
    public var credentialId: String
    public var fieldName: String
    public var sessionId: String?
    public var requestedFieldNames: [String]

    private enum CodingKeys: String, CodingKey {
        case credentialId, fieldName, sessionId, requestedFieldNames
    }

    public init(credentialId: String,
                fieldName: String,
                sessionId: String?,
                requestedFieldNames: [String]? = nil) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.sessionId = sessionId
        self.requestedFieldNames = requestedFieldNames ?? [fieldName]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentialId = try container.decode(String.self, forKey: .credentialId)
        fieldName = try container.decode(String.self, forKey: .fieldName)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        requestedFieldNames = try container.decodeIfPresent([String].self, forKey: .requestedFieldNames)
            ?? [fieldName]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentialId, forKey: .credentialId)
        try container.encode(fieldName, forKey: .fieldName)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(requestedFieldNames, forKey: .requestedFieldNames)
    }
}

public enum ValueErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest
    case notFound
    case noAuthorization
    case authorizationDenied
    case pendingExpired
    case keychainBlocked
    case keychainError
}

/// Optional storage-specific detail for value responses.
///
/// `errorCode` remains populated with a legacy value so older CLI versions can
/// continue decoding responses from a newer app.
public enum ValueStorageErrorCode: String, Codable, Sendable, Equatable {
    case vaultLocked
    case readFailed
}

public struct ValueResponse: Codable, Sendable {
    public var success: Bool
    public var value: String?
    public var error: String?
    public var errorCode: ValueErrorCode?
    public var storageErrorCode: ValueStorageErrorCode?

    public init(success: Bool,
                value: String? = nil,
                error: String? = nil,
                errorCode: ValueErrorCode? = nil,
                storageErrorCode: ValueStorageErrorCode? = nil) {
        self.success = success
        self.value = value
        self.error = error
        self.errorCode = errorCode
        self.storageErrorCode = storageErrorCode
    }
}

public struct AuthRequest: Codable, Sendable {
    public var credentialId: String
    public var credentialLabel: String
    public var fieldNames: [String]
    public var sessionId: String?
    public var sessionLabel: String?
    public var pid: Int32
    public var callerIdentity: CallerIdentity?

    public init(credentialId: String, credentialLabel: String,
                fieldNames: [String], sessionId: String?,
                sessionLabel: String?, pid: Int32,
                callerIdentity: CallerIdentity? = nil) {
        self.credentialId = credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.sessionId = sessionId
        self.sessionLabel = sessionLabel
        self.pid = pid
        self.callerIdentity = callerIdentity
    }
}

public struct AuthResponse: Codable, Sendable {
    public var granted: Bool
    public var grantId: String?
    public var error: String?

    public init(granted: Bool, grantId: String? = nil, error: String? = nil) {
        self.granted = granted
        self.grantId = grantId
        self.error = error
    }
}

public struct ServiceRequestsListRequest: Codable, Sendable {
    public init() {}
}

public struct PendingServiceRequestSummary: Codable, Sendable, Identifiable {
    public var id: String
    public var credentialId: String
    public var credentialLabel: String
    public var fieldNames: [String]
    public var callerDisplayName: String
    public var subjectFingerprint: String
    public var requestedAt: Date
    public var expiresAt: Date

    public init(id: String,
                credentialId: String,
                credentialLabel: String,
                fieldNames: [String],
                callerDisplayName: String,
                subjectFingerprint: String,
                requestedAt: Date,
                expiresAt: Date) {
        self.id = id
        self.credentialId = credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.callerDisplayName = callerDisplayName
        self.subjectFingerprint = subjectFingerprint
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
    }
}

public struct ServiceRequestsListResponse: Codable, Sendable {
    public var requests: [PendingServiceRequestSummary]

    public init(requests: [PendingServiceRequestSummary]) {
        self.requests = requests
    }
}

// MARK: - Wire Format: 4-byte big-endian length prefix + JSON

public enum IPCMessage {
    public static func encode<T: Encodable>(_ message: T) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var length = UInt32(json.count).bigEndian
        var data = Data(bytes: &length, count: 4)
        data.append(json)
        return data
    }

    /// Read exactly `count` bytes from a file descriptor.
    public static func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    /// Read a length-prefixed JSON message from a file descriptor.
    public static func readMessage<T: Decodable>(fd: Int32, as type: T.Type) -> T? {
        guard let lengthData = readExact(fd: fd, count: 4) else { return nil }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 1_000_000 else { return nil }  // sanity check
        guard let jsonData = readExact(fd: fd, count: Int(length)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: jsonData)
    }

    /// Write a length-prefixed JSON message to a file descriptor.
    public static func writeMessage<T: Encodable>(fd: Int32, message: T) throws {
        let data = try encode(message)
        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, data.count)
        }
        if written != data.count {
            throw IPCError.writeFailed
        }
    }
}

public enum IPCError: Error, LocalizedError {
    case connectionFailed
    case writeFailed
    case readFailed
    case timeout
    case denied(String?)
    case appNotRunning
    case appNotResponding
    case noAuthorization(String?)
    case keychainBlocked(String?)
    case vaultLocked
    case vaultReadFailed(String?)
    case appVersionTooOld

    /// Every message ends with what to do next: these strings are what cron logs and
    /// AI agents see, and a bare "denied" sends them guessing.
    public var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to the KeyKeeper app. Run 'keykeeper status' to check it, or 'keykeeper unlock' to start it."
        case .writeFailed:
            return "Failed to send the request to the KeyKeeper app. Retry; if it keeps failing, quit and reopen KeyKeeper."
        case .readFailed:
            return "Failed to read the KeyKeeper app's response. Retry; if it keeps failing, quit and reopen KeyKeeper."
        case .timeout:
            return "Timed out after \(Int(IPCConstants.authTimeout)) s waiting for approval in the KeyKeeper window. Run the command again and click Authorize."
        case .denied(let msg):
            return "Authorization denied\(Self.detail(msg)). Run the command again and choose Authorize in the KeyKeeper window."
        case .appNotRunning:
            return "The KeyKeeper app is not running. Run 'keykeeper unlock' to start it and unlock the vault, or open KeyKeeper from Applications."
        case .appNotResponding:
            return "The KeyKeeper app did not answer the request. Quit and reopen KeyKeeper, then retry."
        case .noAuthorization(let msg):
            return "This caller is not authorized\(Self.detail(msg)). Approve it in the KeyKeeper window, or set the credential to \"Background OK\" in the app so background jobs are approved once per caller. 'keykeeper grants list' shows existing approvals."
        case .keychainBlocked(let msg):
            return "Keychain read failed or timed out\(Self.detail(msg)). Open the KeyKeeper app and check the credential."
        case .vaultLocked:
            return "The vault is locked, so no keys can be read. Run 'keykeeper unlock' in a terminal, or click the lock icon in the menu bar and unlock KeyKeeper."
        case .vaultReadFailed(let msg):
            return "Failed to read from the vault\(Self.detail(msg)). Open the credential in the KeyKeeper app; if it was added before the vault migration, re-enter its values."
        case .appVersionTooOld:
            return "The installed KeyKeeper app is too old for this command. Update the app, then retry."
        }
    }

    private static func detail(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return ": \(message)"
    }
}
