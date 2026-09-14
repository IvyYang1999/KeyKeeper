import Foundation
import KeyKeeperCore

/// Turns the person's answer into the approval that gets stored.
///
/// "While it runs" is the caller's terminal session when it has one, otherwise the process the
/// subject was derived from (the agent app, the script's shell) with its kernel start time.
enum DurationResolution {
    static func issued(_ choice: AuthorizationView.DurationChoice, sessionId: String?, identity: CallerIdentity?,
                       startTime: (Int32) -> Date? = ProcessLiveness.startTime) throws -> ApprovalDuration {
        switch choice {
        case .once: return .once
        case .always: return .always
        case .thisRun:
            if let sessionId, !sessionId.isEmpty { return .terminalSession(sessionId) }
            guard let pid = identity?.subjectPID, let startedAt = startTime(pid) else {
                throw ApprovalIssuanceError.missingTerminalSession
            }
            return .process(pid: pid, startedAt: startedAt)
        }
    }
}
