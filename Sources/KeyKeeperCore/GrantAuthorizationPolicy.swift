import Foundation

public enum GrantAuthorizationPolicy {
    public static let missingTerminalSessionMessage = "无终端会话，请选 Always 或 1 hour"

    public static func validGrantForValueAccess(
        credentialId: String,
        sessionId: String?,
        fingerprint: String? = nil,
        grantStore: GrantStore
    ) throws -> Grant? {
        try grantStore.findValidGrant(credentialId: credentialId, sessionId: sessionId, fingerprint: fingerprint)
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

    /// After a grant issued before grants had an owner is actually used, it belongs to that
    /// caller from then on. Narrowing only; a scoped grant is untouched.
    public static func pinUnscopedGrantAfterUse(
        _ grant: Grant?,
        caller: CallerIdentity?,
        grantStore: GrantStore
    ) throws {
        guard let grant, grant.subjectFingerprint == nil, let caller else { return }
        try grantStore.pinGrantIfUnscoped(id: grant.id, to: caller.subject.fingerprint,
                                          displayName: caller.displayName)
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
