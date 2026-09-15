import SwiftUI
import KeyKeeperCore

enum ActivityTab: String, CaseIterable {
    case access, changes
    static let defaultTab: Self = .access
    var title: String { self == .access ? L("Access log") : L("Change log") }
}

struct PermissionGroup: Identifiable {
    let id: String
    let who: String
    let approvals: [Approval]

    static func build(_ approvals: [Approval]) -> [Self] {
        let credentials = approvals.filter { $0.target.credentialId != nil }
        let grouped = Dictionary(grouping: credentials) { approval in
            GrantIssuancePolicy.mayRemember(subjectFingerprint: approval.subject.fingerprint)
                ? approval.subject.fingerprint : "unknown:" + approval.id
        }
        return grouped.map { id, items in
            let sorted = items.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
            }
            return Self(id: id, who: AccessEntryBuilder.displayName(sorted[0].subject.displayName) ?? L("Unknown Caller"), approvals: sorted)
        }.sorted { $0.who == $1.who ? $0.id < $1.id : $0.who.localizedStandardCompare($1.who) == .orderedAscending }
    }
}

@MainActor final class PermissionPageState: ObservableObject {
    @Published private(set) var approvals: [Approval] = []
    @Published private(set) var available = false
    @Published private(set) var permissive = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var now = Date()
    let store: ApprovalStore

    init(store: ApprovalStore = .shared) { self.store = store }

    func refresh() {
        do {
            let items = try store.all()
            let mode = try store.mode()
            approvals = items
            permissive = mode == .permissive
            available = true
            errorMessage = nil
        } catch {
            available = false
            permissive = false
            errorMessage = L("Approval status could not be read. No permissions were changed.")
        }
        now = Date()
    }

    func isActive(_ approval: Approval) -> Bool {
        available && GrantIssuancePolicy.mayRemember(subjectFingerprint: approval.subject.fingerprint)
            && approval.isValid(now: now, ignoringTerminalSession: true, processAlive: store.processAlive)
    }

    func revoke(_ expected: Approval) {
        do {
            let current = try store.all().first { $0.id == expected.id }
            guard let current else { refresh(); return }
            guard current.subject.fingerprint == expected.subject.fingerprint, current.target == expected.target else {
                errorMessage = L("This approval changed. Go back and select it again.")
                return
            }
            try store.revoke(id: expected.id)
            refresh()
            NotificationCenter.default.post(name: .credentialsChanged, object: nil)
        } catch {
            available = false
            errorMessage = L("Could not revoke this approval. Refresh to check its current status.")
        }
    }
}

enum ActivityDetailCopy {
    static func absolute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppL10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .long
        return formatter.string(from: date)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppL10n.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func text(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return L("Not recorded") }
        return CallerStatedReason.printableLine(raw, limit: 2000)
    }

    /// This is a caller-supplied, previously capped summary, not a recovered full command.
    /// Redact conventional credential arguments without reading any secret store. Arbitrary
    /// unlabelled/encoded secrets cannot be recognised; never promise full secret detection.
    static func command(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return L("Not recorded") }
        let value = #"(?:"[^"\n]*(?:"|$)|'[^'\n]*(?:'|$)|\S+)"#
        let patterns = [
            #"(?i)((?:--?)[\w-]*(?:key|token|password|secret|authorization|header)[\w-]*(?:=|\s+))"# + value,
            #"(?i)(\b[\w]*(?:KEY|TOKEN|PASSWORD|SECRET)[\w]*=)"# + value,
            #"(?i)(\bBearer\s+)\S+"#
        ]
        return patterns.reduce(CallerStatedReason.printableLine(raw, limit: 2000)) { result, pattern in
            result.replacingOccurrences(of: pattern, with: "$1[REDACTED]", options: .regularExpression)
        }
    }
}

enum ActivityDetailLayoutPolicy {
    static func isSplit(width: CGFloat) -> Bool { width >= 900 }
}
