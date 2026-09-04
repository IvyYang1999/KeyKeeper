import Combine
import Foundation

/// Requests that originate outside the SwiftUI tree: `keykeeper://` deep links and the
/// status-bar menu.
///
/// These used to travel over NotificationCenter, which silently dropped them whenever the
/// subscribing view was off screen — and the subscribers lived on the credential list page,
/// so a link arriving while any other page was showing, or before the popover had ever been
/// rendered, was lost with no error at all. Storing the request instead means whichever page
/// renders next can consume it exactly once.
@MainActor
final class UICommandInbox: ObservableObject {
    static let shared = UICommandInbox()

    @Published var pendingAddCredential: DeepLink?
    @Published var pendingSettings = false

    init() {}

    func requestAddCredential(_ link: DeepLink) {
        pendingAddCredential = link
    }

    func requestSettings() {
        pendingSettings = true
    }

    func clearAddCredential() {
        pendingAddCredential = nil
    }

    func clearSettings() {
        pendingSettings = false
    }
}
