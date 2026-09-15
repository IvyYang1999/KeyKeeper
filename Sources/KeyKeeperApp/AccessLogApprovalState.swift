import SwiftUI
import KeyKeeperCore

/// The event says what happened then. This projection says what the same subject may do now.
enum AccessLogApprovalStatus: Equatable {
    case approved, notApproved, unavailable

    static func current(for group: AccessLogGroup, approvals: [Approval]?, now: Date = Date(),
                        processAlive: ProcessAliveCheck = { ProcessLiveness.isAlive(pid: $0, startedAt: $1) }) -> Self {
        guard let approvals else { return .unavailable }
        guard GrantIssuancePolicy.mayRemember(subjectFingerprint: group.fingerprint) else { return .notApproved }
        return approvals.contains { approval in
            approval.subject.fingerprint == group.fingerprint
                && coversRecordedScope(approval, group: group)
                // Audit events have no terminal-session context. Do not borrow another session's approval.
                && approval.isValid(now: now, terminalSession: nil, processAlive: processAlive)
        } ? .approved : .notApproved
    }

    private static func coversRecordedScope(_ approval: Approval, group: AccessLogGroup) -> Bool {
        let fields = group.kind == .approvedUse ? group.approvalFields : [group.detail]
        guard let fields else {
            guard case .credential(let id, let allowed) = approval.target else { return false }
            return id == group.credentialId && allowed == nil && approval.onceFieldsRemaining == nil
        }
        return !fields.isEmpty && fields.allSatisfy {
            approval.target.covers(credentialId: group.credentialId, field: $0) && approval.stillCovers(field: $0)
        }
    }
}

/// Metadata-only reader, injectable so the production page can be tested without a real Keychain.
@MainActor
final class AccessLogApprovalState: ObservableObject {
    @Published private(set) var groups: [AccessLogGroup] = []
    @Published private(set) var approvals: [Approval]?
    @Published private(set) var permissive = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var now = Date()
    let store: ApprovalStore

    init(store: ApprovalStore = .shared) { self.store = store }

    func refresh(now: Date = Date()) {
        do {
            let current = try store.all()
            let events = try store.auditEvents()
            let mode = try store.mode()
            groups = AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: current, auditEvents: events, limit: .max))
            approvals = current
            permissive = mode == .permissive
            errorMessage = nil
        } catch {
            // Keep the history on screen, but never turn a failed read into an approval opportunity.
            approvals = nil
            permissive = false
            errorMessage = L("Approval status could not be read. No permissions were changed.")
        }
        self.now = now
    }

    func status(for group: AccessLogGroup) -> AccessLogApprovalStatus {
        .current(for: group, approvals: approvals, now: now, processAlive: store.processAlive)
    }
}

/// Refresh only while this page has a visible window. The timer never outlives its host view,
/// and automatic retries stop after a read failure until an explicit notification/focus change.
struct AccessLogRefreshObserver: NSViewRepresentable {
    var onRefresh: () -> Void
    var canAutoRefresh: () -> Bool

    func makeNSView(context: Context) -> AccessLogRefreshView { AccessLogRefreshView() }
    func updateNSView(_ view: AccessLogRefreshView, context: Context) {
        view.onRefresh = onRefresh
        view.canAutoRefresh = canAutoRefresh
    }
    static func dismantleNSView(_ view: AccessLogRefreshView, coordinator: ()) { view.stop() }
}

@MainActor
final class AccessLogRefreshView: NSView {
    var onRefresh: () -> Void = {}
    var canAutoRefresh: () -> Bool = { true }
    var isAppActive: () -> Bool = { NSApp.isActive }
    var interval: TimeInterval = 2
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfVisible(automatic: true) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        for name in [Notification.Name.credentialsChanged, NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if let changedWindow = note.object as? NSWindow, changedWindow !== self?.window { return }
                    self?.refreshIfVisible(automatic: false)
                }
            })
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    private func refreshIfVisible(automatic: Bool) {
        guard window?.isVisible == true else { return }
        if automatic && (!isAppActive() || !canAutoRefresh()) { return }
        onRefresh()
    }
}
