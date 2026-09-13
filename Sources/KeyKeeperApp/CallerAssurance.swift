import Foundation
import KeyKeeperCore

/// How much is actually known about the program asking, in the three tiers identity now has.
///
/// 【安全审计 2026-09-13】The prompt showed a name and nothing about whether that name was
/// proven. An unsigned local program and a Developer ID app looked identical. Since identity is
/// now measured from the connection's audit token, the difference is real and worth showing.
enum CallerAssurance: Equatable {
    /// Signature checked out and names a team.
    case signed
    /// Located at connect time, but not signed — normal for local tools and agents.
    case unsigned
    /// Could not be identified at all. Cannot hold an approval.
    case unverified

    static func of(_ subject: CallerSubject) -> CallerAssurance {
        if subject.fingerprint.hasPrefix(CallerSubject.unverifiedPrefix) { return .unverified }
        if subject.fingerprint.hasPrefix("unsigned:") { return .unsigned }
        return .signed
    }

    var label: String {
        switch self {
        case .signed: return L("Signed")
        case .unsigned: return L("Not signed")
        case .unverified: return L("Unidentified")
        }
    }

    var explanation: String {
        switch self {
        case .signed:
            return L("Its signature checks out, so an approval can be remembered for this program alone.")
        case .unsigned:
            return L("A local program with no signature — normal for scripts and agents. KeyKeeper recognises it by the file it runs from.")
        case .unverified:
            return L("KeyKeeper could not work out what is asking, so it cannot remember this decision. It will ask every time.")
        }
    }

    var isReassuring: Bool { self == .signed }

    var symbolName: String {
        switch self {
        case .signed: return "checkmark.seal"
        case .unsigned: return "questionmark.circle"
        case .unverified: return "exclamationmark.triangle"
        }
    }
}
