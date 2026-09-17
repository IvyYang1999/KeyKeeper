import Foundation
import KeyKeeperCore

enum ApprovalAlertPreferences {
    static let soundKey = "approvalSoundEnabled"
    static func shouldPlaySound(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: soundKey)
    }
}

/// Requests waiting for the user's yes or no, gathered in one place.
///
/// The floating prompts still appear (the popover may be closed), but every one of them is
/// also listed here so the menu bar can show a count and answer it inline. Answering in
/// either place calls the same closure the prompt would have called.
@MainActor
final class ApprovalCenter: ObservableObject {
    static let shared = ApprovalCenter()

    struct Item: Identifiable {
        let id: UUID
        /// SF Symbol for the kind of request.
        let symbol: String
        let title: String
        let detail: String
        let expiresAt: Date?
        let confirmTitle: String
        let destructive: Bool
        /// True when confirming needs more input (duration, Touch ID) and so brings the full
        /// prompt forward instead of approving from the list.
        let opensWindow: Bool
        let confirm: () -> Void
        let deny: () -> Void
        var shownAt = Date()

        /// 【独立审计 2026-09-13】the approval window waits out a settle delay; the same request in
        /// this list approved on the first click, so the delay could be walked around entirely.
        /// Items that open the full window get that window's delay instead.
        func canConfirm(now: Date = Date()) -> Bool {
            opensWindow || ApprovalReadiness.canApprove(shownAt: shownAt, now: now)
        }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var missed: [ServiceAuditEvent] = []
    @Published private(set) var missedLoadFailed = false

    private static let dismissedMissedKey = "dismissedMissedApprovalIDs"

    init() {}

    func add(_ item: Item) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    static func visibleMissed(events: [ServiceAuditEvent], dismissed: Set<String>) -> [ServiceAuditEvent] {
        events.filter { event in
            event.decision == "missed_approval" && event.requestID.map { !dismissed.contains($0) } == true
        }.sorted { $0.timestamp > $1.timestamp }
    }

    func refreshMissed(store: ApprovalStore = .shared) {
        do {
            let dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedMissedKey) ?? [])
            missed = Self.visibleMissed(events: try store.auditEvents(), dismissed: dismissed)
            missedLoadFailed = false
        } catch {
            // Preserve what was already shown. Never claim an unread request was dismissed.
            missedLoadFailed = true
        }
    }

    func dismissMissed(id: String) {
        var ids = UserDefaults.standard.stringArray(forKey: Self.dismissedMissedKey) ?? []
        if !ids.contains(id) { ids.append(id) }
        UserDefaults.standard.set(Array(ids.suffix(500)), forKey: Self.dismissedMissedKey)
        missed.removeAll { $0.requestID == id }
    }

    var count: Int { items.count }
}
