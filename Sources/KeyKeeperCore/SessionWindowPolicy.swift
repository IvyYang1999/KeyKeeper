import Foundation

/// How long a logged-in window stays usable, and what happens when that runs out.
///
/// It used to be one hard-coded number and one outcome: 900 seconds, then the window was closed
/// and its data wiped. That punished the person for stepping away — an agent lost everything it
/// was in the middle of, and the only recourse was to start over.
///
/// Now the limit ends *permission*, not the window. At the limit the window freezes: still there,
/// still logged in, but nothing can happen in it until someone authorizes again. Re-authorizing
/// restarts the clock from zero rather than extending the old deadline. A frozen window that
/// nobody answers is still a live session sitting on screen, so it closes for real after a grace
/// period.
public struct SessionWindowPolicy: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case active
        /// Visible and intact, but inert until someone authorizes again.
        case frozen
        case closed
    }

    public static let minimumLimit: TimeInterval = 60
    public static let maximumLimit: TimeInterval = 8 * 3600
    public static let `default` = SessionWindowPolicy(limit: 900, graceAfterFreeze: 600)

    public let limit: TimeInterval
    public let graceAfterFreeze: TimeInterval

    public init(limit: TimeInterval, graceAfterFreeze: TimeInterval) {
        self.limit = min(max(limit, Self.minimumLimit), Self.maximumLimit)
        self.graceAfterFreeze = max(graceAfterFreeze, 60)
    }

    public func state(startedAt: Date, frozenAt: Date?, now: Date) -> State {
        if let frozenAt {
            return now.timeIntervalSince(frozenAt) >= graceAfterFreeze ? .closed : .frozen
        }
        return now.timeIntervalSince(startedAt) >= limit ? .frozen : .active
    }
}
