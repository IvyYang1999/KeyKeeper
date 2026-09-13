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
        fieldName: String,
        grantStore: GrantStore
    ) throws {
        guard let grant else { return }
        if case .once = grant.duration {
            try grantStore.consumeOnceField(id: grant.id, fieldName: fieldName)
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

/// Keys that need approval go only to callers an approval can be held for.
///
/// 【独立审计第二轮】an unidentified caller used to get the prompt anyway: the approval was stored
/// with no owner, could never match the caller that asked, and the CLI's retry showed a second
/// prompt before failing. Refusing up front, with the reason, costs nobody a click.
public enum StrictAuthorizationPolicy {
    public static func refusal(for fingerprint: String) -> String? {
        guard !GrantIssuancePolicy.mayRemember(subjectFingerprint: fingerprint) else { return nil }
        return "KeyKeeper could not identify the program asking (it may have exited, or macOS could not attribute it), so it cannot give it keys that need approval. No prompt was shown. Run the command again from a terminal or an app."
    }
}

