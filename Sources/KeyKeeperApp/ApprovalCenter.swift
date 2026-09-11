import Foundation

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
    }

    @Published private(set) var items: [Item] = []

    init() {}

    func add(_ item: Item) {
        items.removeAll { $0.id == item.id }
        items.append(item)
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
    }

    var count: Int { items.count }
}
