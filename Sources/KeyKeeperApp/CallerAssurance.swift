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

    /// Signed means a real team in the fingerprint. 【2026-09-13 修信使问题时引入】callers found
    /// upstream of the CLI arrive as `app:team=unsigned:…`, `script:…` or `executable:…`, and the
    /// old check — "anything not prefixed unsigned: is signed" — labelled all of them Signed.
    static func of(_ subject: CallerSubject) -> CallerAssurance {
        let fingerprint = subject.fingerprint
        if fingerprint.hasPrefix(CallerSubject.unverifiedPrefix) { return .unverified }
        if fingerprint.hasPrefix("app:team="), !fingerprint.hasPrefix("app:team=unsigned:") { return .signed }
        return .unsigned
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

extension CallerAssurance {
    /// What "Allow" covers, said per tier.
    ///
    /// 【独立审计 2026-09-13】the window said "only X, not other programs on this Mac" for every
    /// caller. For an unsigned caller that is false — KeyKeeper knows it by the file it runs from,
    /// and anything started from that file is it — and for an unidentified one nothing is
    /// remembered at all.
    func scope(caller: String, wholeCredential: Bool) -> UILocalizedString {
        switch (self, wholeCredential) {
        case (.signed, true):
            return "Allowing lets \(caller) read every key in this credential — only \(caller), not other programs on this Mac. \u{201C}Always allow\u{201D} also covers its future sessions, until you revoke it."
        case (.signed, false):
            return "Allowing lets \(caller) read this key — only \(caller), not other programs on this Mac. \u{201C}Always\u{201D} lasts until you revoke it."
        case (.unsigned, true):
            return "Allowing lets \(caller) read every key in this credential. KeyKeeper recognises it by the file it runs from, so anything started from that same file counts as it too. \u{201C}Always allow\u{201D} also covers its future sessions, until you revoke it."
        case (.unsigned, false):
            return "Allowing lets \(caller) read this key. KeyKeeper recognises it by the file it runs from, so anything started from that same file counts as it too. \u{201C}Always\u{201D} lasts until you revoke it."
        case (.unverified, _):
            return "KeyKeeper could not identify \(caller), so this answer covers this request only and is not remembered."
        }
    }

    /// Whether an approval can be remembered for this caller at all (see GrantIssuancePolicy).
    var canRemember: Bool { self != .unverified }

    func scopeLine(caller: String, wholeCredential: Bool) -> String {
        L(scope(caller: caller, wholeCredential: wholeCredential))
    }
}
