import Foundation

// MARK: - Socket Path

public enum IPCConstants {
    public static var socketPath: String {
        resolveSocketPath(environment: ProcessInfo.processInfo.environment)
    }

    /// A separate socket is admitted only together with isolated data and a test Keychain service.
    static func resolveSocketPath(environment: [String: String]) -> String {
        let isolationKeys = ["KEYKEEPER_TEST_SOCKET", KeyKeeperPaths.dataDirectoryEnvironmentKey,
                             SecItemBlobIO.serviceEnvironmentKey]
        if let candidate = environment["KEYKEEPER_TEST_SOCKET"],
           candidate.hasPrefix("/tmp/keykeeper-test-"), candidate.utf8.count <= 103,
           !candidate.dropFirst(5).contains("/"), !candidate.contains("\0"),
           environment[KeyKeeperPaths.dataDirectoryEnvironmentKey]?.isEmpty == false,
           environment[SecItemBlobIO.serviceEnvironmentKey]?.hasPrefix("com.keykeeper.test.") == true {
            return candidate
        }
        // 【曾经的 bug】A misspelled/incomplete E2E triple used to become the production socket.
        // The CLI then talked to the real App while the test believed it was isolated. Give any
        // invalid isolation attempt a per-process dead end: the App and CLI have different PIDs,
        // so they cannot accidentally meet, while repeated lookups inside one process stay stable.
        if isolationKeys.contains(where: { environment[$0] != nil }) {
            return "/tmp/keykeeper-test-invalid-\(ProcessInfo.processInfo.processIdentifier).sock"
        }
        return "/tmp/keykeeper-\(NSUserName()).sock"
    }

    /// Bounded operations (imports, session control, and legacy interactive Keychain reads).
    /// Live credential authorization itself no longer has a clock deadline.
    public static let authTimeout: TimeInterval = 120
    /// Grace period for bounded operations that still use authTimeout.
    public static let clientGrace: TimeInterval = 15

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
    case browserSession(BrowserSessionRequest)
    case fileImport(FileImportRequest)
    case sourceImport(SourceImportRequest)
    case envImport(EnvImportRequest)
    case browserImport(ClipboardSaveRequest)
    case browserImportProposal(BrowserImportProposalRequest)
    case clipboardSave(ClipboardSaveRequest)
    case auth(AuthRequest)
    case value(ValueRequest)
    case serviceRequests(ServiceRequestsListRequest)
    case sessionControl(SessionControlRequest)
    case metadataEdit(MetadataEditRequest)
    case metadataIntegrity(MetadataIntegrityRequest)
    case approvalRevoke(ApprovalRevokeRequest)
    case approvalsList(ApprovalsListRequest)

    private enum CodingKeys: String, CodingKey { case type, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .metadataEdit(let r):
            try c.encode("metadataEdit", forKey: .type)
            try c.encode(r, forKey: .data)
        case .metadataIntegrity(let r):
            try c.encode("metadataIntegrity", forKey: .type)
            try c.encode(r, forKey: .data)
        case .approvalRevoke(let r):
            try c.encode("approvalRevoke", forKey: .type)
            try c.encode(r, forKey: .data)
        case .approvalsList(let r):
            try c.encode("approvalsList", forKey: .type)
            try c.encode(r, forKey: .data)
        case .browserSession(let r):
            try c.encode("browserSession", forKey: .type)
            try c.encode(r, forKey: .data)
        case .sourceImport(let r):
            try c.encode("sourceImport", forKey: .type)
            try c.encode(r, forKey: .data)
        case .fileImport(let r):
            try c.encode("fileImport", forKey: .type)
            try c.encode(r, forKey: .data)
        case .envImport(let r):
            try c.encode("envImport", forKey: .type)
            try c.encode(r, forKey: .data)
        case .browserImport(let r):
            try c.encode("browserImport", forKey: .type)
            try c.encode(r, forKey: .data)
        case .browserImportProposal(let r):
            try c.encode("browserImportProposal", forKey: .type)
            try c.encode(r, forKey: .data)
        case .clipboardSave(let r):
            // Old Apps reject this discriminator instead of silently ignoring new safeguards.
            try c.encode(r.isReplacement || r.expectedEd25519PublicKey != nil ? "clipboardReplace" : "clipboardSave", forKey: .type)
            try c.encode(r, forKey: .data)
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
        case "browserSession": self = .browserSession(try c.decode(BrowserSessionRequest.self, forKey: .data))
        case "fileImport": self = .fileImport(try c.decode(FileImportRequest.self, forKey: .data))
        case "sourceImport": self = .sourceImport(try c.decode(SourceImportRequest.self, forKey: .data))
        case "envImport": self = .envImport(try c.decode(EnvImportRequest.self, forKey: .data))
        case "browserImport": self = .browserImport(try c.decode(ClipboardSaveRequest.self, forKey: .data))
        case "browserImportProposal": self = .browserImportProposal(try c.decode(BrowserImportProposalRequest.self, forKey: .data))
        case "clipboardSave", "clipboardReplace":
            let request = try c.decode(ClipboardSaveRequest.self, forKey: .data)
            let protectedRequest = request.isReplacement || request.expectedEd25519PublicKey != nil
            guard (try c.decode(String.self, forKey: .type) == "clipboardReplace") == protectedRequest else {
                throw ClipboardSaveError.invalidReplacement
            }
            self = .clipboardSave(request)
        case "auth":  self = .auth(try c.decode(AuthRequest.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueRequest.self, forKey: .data))
        case "serviceRequests": self = .serviceRequests(try c.decode(ServiceRequestsListRequest.self, forKey: .data))
        case "sessionControl": self = .sessionControl(try c.decode(SessionControlRequest.self, forKey: .data))
        case "metadataEdit": self = .metadataEdit(try c.decode(MetadataEditRequest.self, forKey: .data))
        case "metadataIntegrity": self = .metadataIntegrity(try c.decode(MetadataIntegrityRequest.self, forKey: .data))
        case "approvalRevoke": self = .approvalRevoke(try c.decode(ApprovalRevokeRequest.self, forKey: .data))
        case "approvalsList": self = .approvalsList(try c.decode(ApprovalsListRequest.self, forKey: .data))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c, debugDescription: "Unknown IPC request type")
        }
    }
}

public enum IPCResponse: Codable, Sendable {
    case browserSession(BrowserSessionResponse)
    case browserImportReady(String)
    case browserImportProposal(BrowserImportProposalResponse)
    case clipboardSave(ClipboardSaveResponse)
    case auth(AuthResponse)
    case value(ValueResponse)
    case serviceRequests(ServiceRequestsListResponse)
    case sessionControl(SessionControlResponse)
    case metadataEdit(MetadataEditResponse)
    case metadataIntegrity(MetadataIntegrityResponse)
    case approvalRevoke(ApprovalRevokeResponse)
    case approvalsList(ApprovalsListResponse)

    private enum CodingKeys: String, CodingKey { case type, data }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .metadataEdit(let r):
            try c.encode("metadataEdit", forKey: .type)
            try c.encode(r, forKey: .data)
        case .metadataIntegrity(let r):
            try c.encode("metadataIntegrity", forKey: .type)
            try c.encode(r, forKey: .data)
        case .approvalRevoke(let r):
            try c.encode("approvalRevoke", forKey: .type)
            try c.encode(r, forKey: .data)
        case .approvalsList(let r):
            try c.encode("approvalsList", forKey: .type)
            try c.encode(r, forKey: .data)
        case .browserSession(let r):
            try c.encode("browserSession", forKey: .type)
            try c.encode(r, forKey: .data)
        case .browserImportReady(let url):
            try c.encode("browserImportReady", forKey: .type)
            try c.encode(url, forKey: .data)
        case .browserImportProposal(let r):
            try c.encode("browserImportProposal", forKey: .type)
            try c.encode(r, forKey: .data)
        case .clipboardSave(let r):
            try c.encode("clipboardSave", forKey: .type)
            try c.encode(r, forKey: .data)
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
        case "browserSession": self = .browserSession(try c.decode(BrowserSessionResponse.self, forKey: .data))
        case "browserImportReady": self = .browserImportReady(try c.decode(String.self, forKey: .data))
        case "browserImportProposal": self = .browserImportProposal(try c.decode(BrowserImportProposalResponse.self, forKey: .data))
        case "clipboardSave": self = .clipboardSave(try c.decode(ClipboardSaveResponse.self, forKey: .data))
        case "auth":  self = .auth(try c.decode(AuthResponse.self, forKey: .data))
        case "value": self = .value(try c.decode(ValueResponse.self, forKey: .data))
        case "serviceRequests": self = .serviceRequests(try c.decode(ServiceRequestsListResponse.self, forKey: .data))
        case "sessionControl": self = .sessionControl(try c.decode(SessionControlResponse.self, forKey: .data))
        case "metadataEdit": self = .metadataEdit(try c.decode(MetadataEditResponse.self, forKey: .data))
        case "metadataIntegrity": self = .metadataIntegrity(try c.decode(MetadataIntegrityResponse.self, forKey: .data))
        case "approvalRevoke": self = .approvalRevoke(try c.decode(ApprovalRevokeResponse.self, forKey: .data))
        case "approvalsList": self = .approvalsList(try c.decode(ApprovalsListResponse.self, forKey: .data))
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
    public var inspectValues: Bool?

    public init(action: SessionControlAction, passphrase: String? = nil, inspectValues: Bool? = nil) {
        self.action = action
        self.passphrase = passphrase
        self.inspectValues = inspectValues
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
    /// Optional for old peers. Only field names; no secret values or grants.
    public var valueInventory: [String: [String]]?
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
    /// What the caller says it needs the value for. Shown in the prompt, never trusted.
    public var statedReason: CallerStatedReason?
    public var requestedDuration: RequestedDuration?
    public var commandSummary: String?
    /// What the value is for. Honoured only when the request arrived through KeyKeeper's own
    /// CLI, which sets it truthfully; anything else claiming `inject` is not believed.
    public var purpose: ValuePurpose?

    private enum CodingKeys: String, CodingKey {
        case credentialId, fieldName, sessionId, requestedFieldNames, statedReason, requestedDuration, commandSummary, purpose
    }

    public init(credentialId: String,
                fieldName: String,
                sessionId: String?,
                requestedFieldNames: [String]? = nil,
                statedReason: CallerStatedReason? = nil,
                requestedDuration: RequestedDuration? = nil,
                commandSummary: String? = nil,
                purpose: ValuePurpose? = nil) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.sessionId = sessionId
        self.requestedFieldNames = requestedFieldNames ?? [fieldName]
        self.statedReason = statedReason
        self.requestedDuration = requestedDuration
        self.commandSummary = commandSummary
        self.purpose = purpose
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        credentialId = try container.decode(String.self, forKey: .credentialId)
        fieldName = try container.decode(String.self, forKey: .fieldName)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        requestedFieldNames = try container.decodeIfPresent([String].self, forKey: .requestedFieldNames)
            ?? [fieldName]
        statedReason = try container.decodeIfPresent(CallerStatedReason.self, forKey: .statedReason)
        requestedDuration = try container.decodeIfPresent(RequestedDuration.self, forKey: .requestedDuration)
        commandSummary = try container.decodeIfPresent(String.self, forKey: .commandSummary)
        purpose = try container.decodeIfPresent(ValuePurpose.self, forKey: .purpose)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(credentialId, forKey: .credentialId)
        try container.encode(fieldName, forKey: .fieldName)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encode(requestedFieldNames, forKey: .requestedFieldNames)
        try container.encodeIfPresent(statedReason, forKey: .statedReason)
        try container.encodeIfPresent(requestedDuration, forKey: .requestedDuration)
        try container.encodeIfPresent(commandSummary, forKey: .commandSummary)
        try container.encodeIfPresent(purpose, forKey: .purpose)
    }
}

/// Why a value is being asked for.
public enum ValuePurpose: String, Codable, Sendable, Equatable {
    /// `keykeeper run`: into a child process's environment, never printed.
    case inject
    /// `keykeeper get` and the SDKs: handed back to the caller.
    case read
}

/// yyt 2026-09-14: "`keykeeper get` isn't a terminal for an agent's Bash tool, it's a pipe — the
/// value lands in its context." A credential marked inject-only is served only to KeyKeeper's own
/// CLI (recognised from the connection, `relayed:` subjects) and only for `run`.
public enum InjectOnlyPolicy {
    public static func refusal(credential: Credential, purpose: ValuePurpose?, caller: CallerIdentity) -> String? {
        guard credential.isInjectOnly else { return nil }
        let viaOwnCLI = caller.subject.fingerprint.hasPrefix(CallerSubject.relayedPrefix)
        guard viaOwnCLI, purpose == .inject else {
            return "This credential is inject-only: its values go into a command's environment through `keykeeper run -c <id> -- <command>` and are never handed back. The person can allow reading it out in KeyKeeper (credential page → Can be read out)."
        }
        return nil
    }
}

public enum ValueErrorCode: String, Codable, Sendable, Equatable {
    case invalidRequest
    case notFound
    case noAuthorization
    /// The credential only goes into a `keykeeper run` environment; reading it out is refused.
    case injectOnly
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
    /// What the caller says it needs the key for. Shown in the prompt, never trusted.
    public var statedReason: CallerStatedReason?
    /// How long the caller asks to be approved for. A wish, checked against its declaration.
    public var requestedDuration: RequestedDuration?
    /// The command line about to run, as the caller reports it. Shown, never trusted.
    public var commandSummary: String?

    public init(credentialId: String, credentialLabel: String,
                fieldNames: [String], sessionId: String?,
                sessionLabel: String?, pid: Int32,
                callerIdentity: CallerIdentity? = nil,
                statedReason: CallerStatedReason? = nil,
                requestedDuration: RequestedDuration? = nil,
                commandSummary: String? = nil) {
        self.credentialId = credentialId
        self.credentialLabel = credentialLabel
        self.fieldNames = fieldNames
        self.sessionId = sessionId
        self.sessionLabel = sessionLabel
        self.pid = pid
        self.callerIdentity = callerIdentity
        self.statedReason = statedReason
        self.requestedDuration = requestedDuration
        self.commandSummary = commandSummary
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

    /// The same entry with the one field only KeyKeeper itself needs removed.
    ///
    /// 【安全审计 2026-09-13】This list is readable by any local process, and it carried each
    /// pending request's caller fingerprint — a ready-made answer to "what exactly do I have to
    /// look like to be mistaken for them". The list stays; that field does not.
    public func redactedForCaller() -> PendingServiceRequestSummary {
        var copy = self
        copy.subjectFingerprint = ""
        return copy
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
    public static func readExact(fd: Int32, count: Int, deadline: Date? = nil) -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        // Monotonic, not the wall clock: a clock change or sleep must not cut a request short or
        // stretch it without end. 【独立审计第二轮】
        let limit = deadline.map { ProcessInfo.processInfo.systemUptime + $0.timeIntervalSinceNow }
        while offset < count {
            // The per-read socket timeout restarts on every byte, so a caller that dribbles one
            // byte at a time can hold the server's serial queue open indefinitely. A deadline for
            // the whole message is what actually bounds it — and it has to be enforced by waiting
            // with poll(), not by checking the clock before a read that then blocks anyway.
            if let limit {
                let remaining = limit - ProcessInfo.processInfo.systemUptime
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                // Past the deadline this is a zero-length wait: what has already arrived is still read.
                let ready = poll(&poller, 1, Int32(max(0, min(remaining * 1000, 3_600_000)).rounded(.up)))
                if ready < 0 && errno == EINTR { continue }
                if ready == 0 {
                    // A signal, or the one-hour cap on a single wait, is not the deadline.
                    if remaining > 0 { continue }
                    return nil
                }
                guard ready > 0 else { return nil }
            }
            let n = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!.advanced(by: offset), count - offset)
            }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            offset += n
        }
        return buffer
    }

    /// Read a length-prefixed JSON message from a file descriptor.
    /// How long one message may take to arrive, in total. Without this, the per-read timeout is
    /// restarted by every byte and a slow sender holds the server for as long as it likes.
    public static let messageDeadline: TimeInterval = 15

    /// `deadline` is for the server reading a request, and nothing else.
    ///
    /// 【曾经的 bug】it briefly defaulted to 15 seconds, which made the CLI give up on every
    /// response that needs a person — an approval window routinely stays open longer than that —
    /// so every prompt-requiring command failed while the person was still reading the prompt.
    /// Clients that await a person pass no deadline and do not set a receive timeout.
    public static func readMessage<T: Decodable>(fd: Int32, as type: T.Type,
                                                 deadline: TimeInterval? = nil) -> T? {
        let limit = deadline.map { Date().addingTimeInterval($0) }
        guard let lengthData = readExact(fd: fd, count: 4, deadline: limit) else { return nil }
        let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length > 0, length < 1_000_000 else { return nil }  // sanity check
        guard let jsonData = readExact(fd: fd, count: Int(length), deadline: limit) else { return nil }
        return try? JSONDecoder().decode(T.self, from: jsonData)
    }

    /// Write a length-prefixed JSON message to a file descriptor.
    /// Write one framed message, all of it.
    ///
    /// 【独立审计 2026-09-13】this used to be a single write(): under a send timeout a large
    /// response went out in pieces and was reported as failed after the first piece was already on
    /// the wire; and with no bound at all, a peer that stopped reading held the server's serial
    /// queue. `deadline` is for the server — the whole write has to finish inside it.
    public static func writeMessage<T: Encodable>(fd: Int32, message: T, deadline: TimeInterval? = nil) throws {
        let data = try encode(message)
        let limit = deadline.map { ProcessInfo.processInfo.systemUptime + $0 }
        var restoreFlags: Int32?
        if limit != nil {
            // Non-blocking for the duration, so poll() is what waits and the deadline holds even
            // when the peer frees buffer space a byte at a time.
            let flags = fcntl(fd, F_GETFL)
            if flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 { restoreFlags = flags }
        }
        defer { if let restoreFlags { _ = fcntl(fd, F_SETFL, restoreFlags) } }
        var offset = 0
        while offset < data.count {
            if let limit {
                let remaining = limit - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw IPCError.writeFailed }
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&poller, 1, Int32(min(remaining * 1000, 3_600_000).rounded(.up)))
                if ready == 0 || (ready < 0 && errno == EINTR) { continue }
                guard ready > 0 else { throw IPCError.writeFailed }
            }
            let n = data.withUnsafeBytes { ptr in
                Darwin.write(fd, ptr.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EINTR { continue }
            // Without a deadline the socket's own send timeout is the limit, and EAGAIN means it ran
            // out with nothing written: retrying would never return. 【独立审计第二轮】
            if n < 0 && errno == EAGAIN && limit != nil { continue }
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
            return "Failed to connect to the KeyKeeper app. Open KeyKeeper from Applications, then retry."
        case .writeFailed:
            return "Failed to send the request to the KeyKeeper app. Retry; if it keeps failing, quit and reopen KeyKeeper."
        case .readFailed:
            return "Failed to read the KeyKeeper app's response. Retry; if it keeps failing, quit and reopen KeyKeeper."
        case .timeout:
            return "The authorization request ended before KeyKeeper answered. Run the command again; if it keeps failing, reopen KeyKeeper."
        case .denied(let msg):
            return "Authorization denied\(Self.detail(msg)). Run the command again and choose Authorize in the KeyKeeper window."
        case .appNotRunning:
            return "The KeyKeeper app could not be started. Open KeyKeeper from Applications, then retry."
        case .appNotResponding:
            return "The KeyKeeper app did not answer the request. Quit and reopen KeyKeeper, then retry."
        case .noAuthorization(let msg):
            return "This caller is not authorized\(Self.detail(msg)). Approve it in the KeyKeeper window, or set the credential to \"Background OK\" in the app so background jobs are approved once per caller. 'keykeeper grants list' shows existing approvals."
        case .keychainBlocked(let msg):
            return "Keychain read failed or timed out\(Self.detail(msg)). Open the KeyKeeper app and check the credential."
        case .vaultLocked:
            return "KeyKeeper could not read this key right now. Open the KeyKeeper app, then retry."
        case .vaultReadFailed(let msg):
            return "Failed to read this key from storage\(Self.detail(msg)). Open the credential in the KeyKeeper app and check it; re-enter the value if needed."
        case .appVersionTooOld:
            return "The installed KeyKeeper app is too old for this command. Update the app, then retry."
        }
    }

    private static func detail(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "" }
        return ": \(message)"
    }
}

// MARK: - Metadata edits (names and notes, never values)

/// `keykeeper edit`: rename a credential or its fields, or change title, notes and field
/// display names. Applied by the App without a prompt and recorded in its change log.
public struct MetadataEditRequest: Codable, Sendable, Equatable {
    /// Current or earlier group ID.
    public var groupId: String
    public var edit: MetadataEdit

    public init(groupId: String, edit: MetadataEdit) {
        self.groupId = groupId
        self.edit = edit
    }
}

public struct MetadataEditResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var error: String?
    /// The group ID after the edit.
    public var groupId: String?
    public var changes: [MetadataChange]

    public init(success: Bool, error: String? = nil, groupId: String? = nil, changes: [MetadataChange] = []) {
        self.success = success
        self.error = error
        self.groupId = groupId
        self.changes = changes
    }
}

// MARK: - Metadata integrity

/// "Is meta.json still the file you wrote?" — asked by the CLI before it hands out a plain value.
public struct MetadataIntegrityRequest: Codable, Sendable, Equatable {
    public init() {}
}

public struct MetadataIntegrityResponse: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case intact, unsigned, tampered }
    public var verdict: Verdict
    public init(verdict: Verdict) { self.verdict = verdict }

    public init(_ verdict: MetaIntegrity.Verdict) {
        switch verdict {
        case .intact: self.verdict = .intact
        case .unsigned: self.verdict = .unsigned
        case .tampered: self.verdict = .tampered
        }
    }
}

/// Whether the CLI may hand out a value it read straight from meta.json.
///
/// The CLI serves plain fields itself — it never asks the app for them — so signing meta.json
/// only on the app's side would leave the exact attack open: flip `secret: true` to false, put a
/// value in, and `keykeeper get` returns it. The CLI cannot read the signing key without a
/// Keychain prompt, so it asks the app. No answer means no: otherwise killing the app would be
/// the way around the check.
public enum PlainValuePolicy {
    public static func mayServe(_ verdict: MetadataIntegrityResponse.Verdict?) -> Bool {
        switch verdict {
        case .intact, .unsigned: return true
        case .tampered, .none: return false
        }
    }
}

/// Approvals live in a Keychain item only the app can open, so listing and revoking go through
/// it. Narrowing access needs no prompt; the CLI never touches the store itself.
public struct ApprovalRevokeRequest: Codable, Sendable, Equatable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct ApprovalRevokeResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var error: String?
    public init(success: Bool, error: String? = nil) {
        self.success = success
        self.error = error
    }
}

public struct ApprovalsListRequest: Codable, Sendable, Equatable {
    public var credentialId: String?
    public init(credentialId: String? = nil) { self.credentialId = credentialId }
}

public struct ApprovalsListResponse: Codable, Sendable, Equatable {
    public var mode: ServiceAuthorizationMode
    public var approvals: [Approval]
    public init(mode: ServiceAuthorizationMode, approvals: [Approval]) {
        self.mode = mode
        self.approvals = approvals
    }
}
