import Foundation

public enum GrantAuthorizationPolicy {
    public static let missingTerminalSessionMessage = "无终端会话，请选 Always 或 1 hour"

    public static func validGrantForValueAccess(
        credentialId: String,
        sessionId: String?,
        grantStore: GrantStore
    ) throws -> Grant? {
        try grantStore.findValidGrant(credentialId: credentialId, sessionId: sessionId)
    }

    public static func resolveIssuedDuration(
        requestedDuration: GrantDuration,
        requestSessionId: String?
    ) throws -> GrantDuration {
        switch requestedDuration {
        case .session:
            guard let requestSessionId, !requestSessionId.isEmpty else {
                throw GrantAuthorizationError.missingTerminalSession
            }
            return .session(requestSessionId)
        case .once, .timed, .always:
            return requestedDuration
        }
    }

    public static func consumeOnceGrantAfterSuccessfulValueIfNeeded(
        _ grant: Grant?,
        grantStore: GrantStore
    ) throws {
        guard let grant else { return }
        if case .once = grant.duration {
            try grantStore.consumeGrant(id: grant.id)
        }
    }
}

public enum GrantAuthorizationError: Error, LocalizedError, Equatable {
    case missingTerminalSession

    public var errorDescription: String? {
        switch self {
        case .missingTerminalSession:
            return GrantAuthorizationPolicy.missingTerminalSessionMessage
        }
    }
}
