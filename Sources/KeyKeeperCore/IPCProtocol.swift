import Foundation

// MARK: - Socket Path

public enum IPCConstants {
    public static var socketPath: String {
        "/tmp/keykeeper-\(NSUserName()).sock"
    }

    /// Maximum time (seconds) CLI waits for authorization response
    public static let authTimeout: TimeInterval = 120
}

// MARK: - Request / Response Envelopes

public enum IPCRequest: Codable, Sendable {
    case auth(AuthRequest)
    case value(ValueRequest)

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
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "auth":  self = .auth(try c.decode(AuthRequest.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueRequest.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown IPC request type")
        }
    }
}

public enum IPCResponse: Codable, Sendable {
    case auth(AuthResponse)
    case value(ValueResponse)

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
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "auth":  self = .auth(try c.decode(AuthResponse.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueResponse.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown IPC response type")
        }
    }
}

// MARK: - Messages

public struct ValueRequest: Codable, Sendable {
    public var credentialId: String
    public var fieldName: String
    public var sessionId: String?

    public init(credentialId: String, fieldName: String, sessionId: String?) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.sessionId = sessionId
    }
}

public struct ValueResponse: Codable, Sendable {
    public var success: Bool
    public var value: String?
    public var error: String?

    public init(success: Bool, value: String? = nil, error: String? = nil) {
        self.success = success
        self.value = value
        self.error = error
    }
}

public struct AuthRequest: Codable, Sendable {
    public var credentialId: String
    public var credentialLabel: String
    public var fieldNames: [String]
    public var sessionId: String?
    public var sessionLabel: String?
    public var pid: Int32

    public init(credentialId: String, credentialLabel: String,
                fieldNames: [String], sessionId: String?,
                sessionLabel: String?, pid: Int32) {
        self.credentialId = credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.sessionId = sessionId
        self.sessionLabel = sessionLabel
        self.pid = pid
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

    public var errorDescription: String? {
        switch self {
        case .connectionFailed: return "Failed to connect to KeyKeeper app"
        case .writeFailed: return "Failed to send authorization request"
        case .readFailed: return "Failed to read authorization response"
        case .timeout: return "Authorization timed out (waiting for user)"
        case .denied(let msg): return "Authorization denied\(msg.map { ": \($0)" } ?? "")"
        case .appNotRunning: return "KeyKeeper app is not running. Launch it from Applications."
        }
    }
}
