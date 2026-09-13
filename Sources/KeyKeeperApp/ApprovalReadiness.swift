import Foundation

/// When a freshly shown approval window is allowed to be approved.
///
/// 【安全审计 2026-09-13】The window takes focus on every request and bound "Authorize" to an
/// unmodified Return. Someone typing elsewhere presses Return, a prompt arrives, and that
/// keystroke approves it. Removing the Return binding handles the keyboard; this handles the
/// mouse: a click already on its way cannot land on a window that just appeared.
///
/// Denial is never delayed. Keeping someone from saying no is indefensible.
enum ApprovalReadiness {
    static let settleDelay: TimeInterval = 0.5

    static func canApprove(shownAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(shownAt) >= settleDelay
    }

    static func canDeny(shownAt: Date, now: Date = Date()) -> Bool { true }
}
