import Foundation
import KeyKeeperCore

@MainActor protocol BrowserSessionRuntime: AnyObject {
    var activeIDs: [String] { get }
    func validate(_ snapshot: BrowserSessionImport) throws
    /// Called by the runtime when an open window's time runs out.
    func setReauthorizationHandler(_ handler: @escaping (String, @escaping (Bool) -> Void) -> Void)
    /// `bringToFront` is false when nobody just approved this: a window opened under a standing
    /// permission must not jump in front of whatever the person is typing into.
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool, completion: @escaping (Bool) -> Void)
    func stop(id: String)
    func stopAll()
}

extension BrowserSessionRuntime {
    func validate(_ snapshot: BrowserSessionImport) throws {}
    func setReauthorizationHandler(_ handler: @escaping (String, @escaping (Bool) -> Void) -> Void) {}
}

struct BrowserSessionPresentation {
    let action: BrowserSessionRequest.Action
    let session: BrowserSessionSummary
    let caller: String
    /// Offer "once / 1 hour / always". Only for opening, and only for a caller KeyKeeper can identify.
    var offersDurations = false
}

@MainActor final class BrowserSessionController: ObservableObject {
    @Published private(set) var sessions: [BrowserSessionSummary] = []
    @Published private(set) var errorCode: BrowserSessionError?
    @Published private(set) var isPending = false
    var otherApprovalPending: () -> Bool = { false }
    private let store: BrowserSessionStore
    private let runtime: BrowserSessionRuntime
    private let now: () -> Date
    private let present: (BrowserSessionPresentation, @escaping (Bool) -> Void) -> Void
    private let dismiss: () -> Void
    private var timer: Timer?
    private struct Pending {
        let ticket: UUID
        let request: BrowserSessionRequest
        let deadline: Date
        let connected: () -> Bool
        let completion: (BrowserSessionResponse) -> Void
    }
    private var pending: Pending?
    private var openingID: String?
    /// Whether a person just clicked Allow for the window about to open — the only case where it
    /// may take over the screen.
    private var humanApprovedOpen = true
    /// Who asked for the pending request, so an approval can be remembered for them alone.
    private var pendingFingerprint: String?
    /// The prompt that also asks how long. Nil keeps every approval single-use.
    private let presentWithDuration: ((BrowserSessionPresentation, @escaping (ApprovalDuration?) -> Void) -> Void)?
    /// Standing permissions to open a login, kept with every other approval.
    private let approvals: ApprovalStore
    var activeIDs: [String] { runtime.activeIDs }

    init(store: BrowserSessionStore, runtime: BrowserSessionRuntime, now: @escaping () -> Date = Date.init,
         present: @escaping (BrowserSessionPresentation, @escaping (Bool) -> Void) -> Void,
         dismiss: @escaping () -> Void,
         presentWithDuration: ((BrowserSessionPresentation, @escaping (ApprovalDuration?) -> Void) -> Void)? = nil,
         approvals: ApprovalStore) {
        self.store = store; self.runtime = runtime; self.now = now; self.present = present; self.dismiss = dismiss
        self.approvals = approvals
        self.presentWithDuration = presentWithDuration
        // The protocol is @MainActor, so this already runs there: answering synchronously keeps
        // "Background OK" invisible — the veil goes up and comes down without a frame in between.
        runtime.setReauthorizationHandler { [weak self] id, decided in
            MainActor.assumeIsolated { self?.authorizeAgain(id: id, decided: decided) }
        }
    }

    /// An open window has reached its limit and frozen. Whether that costs anyone a click is the
    /// session's own setting — the same one a credential has.
    func authorizeAgain(id: String, decided: @escaping (Bool) -> Void) {
        guard let summary = sessions.first(where: { $0.id == id })
            ?? (try? store.list())?.first(where: { $0.id == id }) else { decided(false); return }
        guard summary.security == .strict else {
            // Background OK: the limit is a safety net, not a question.
            decided(true); return
        }
        guard pending == nil else { decided(false); return }
        present(.init(action: .open, session: summary, caller: L("Session window"))) { [weak self] granted in
            self?.dismiss()
            decided(granted)
        }
    }

    /// "Just this once" stores nothing: it is this request. Longer answers become a grant for this
    /// caller and this login only.
    private func remember(_ duration: ApprovalDuration, sessionId: String, fingerprint: String, caller: String) {
        if case .once = duration { return }
        try? approvals.add(Approval(subject: ApprovalSubject(fingerprint: fingerprint, displayName: caller),
                                    target: .session(id: sessionId), duration: duration, createdAt: now()))
        objectWillChange.send()
    }

    /// Who may open this login without asking, for the sessions page.
    func approvals(for sessionId: String) -> [Approval] {
        ((try? approvals.approvals(forSession: sessionId)) ?? []).filter { $0.isValid(now: now()) }
    }

    func revokeApproval(id: String) {
        try? approvals.revoke(id: id)
        objectWillChange.send()
    }

    func refresh() {
        do { sessions = try store.list(); errorCode = nil }
        catch { sessions = []; errorCode = .unavailable }
    }

    /// `fingerprint` identifies the calling program the way a service grant does. Without it a
    /// standing permission would mean "any process on this Mac", which is not what anyone means
    /// to grant — and is exactly what a strict key grant unfortunately does today.
    func receive(_ request: BrowserSessionRequest, caller: String, fingerprint: String? = nil,
                 isConnected: @escaping () -> Bool = { true },
                 completion: @escaping (BrowserSessionResponse) -> Void) {
        do {
            try request.validate()
            guard isConnected() else { throw BrowserSessionError.disconnected }
            if request.action == .stop {
                // Stopping a window is harmless, but it used to also tear down a pending approval
                // for that session — so any local process could cancel a window the person was in
                // the middle of allowing. Only whoever asked for it may take it back.
                let ownsPending = pending == nil || pendingFingerprint == nil || pendingFingerprint == fingerprint
                if ownsPending,
                   openingID == request.id || (pending?.request.action == .open && pending?.request.id == request.id) {
                    finish(.init(success: false, errorCode: .denied))
                }
                runtime.stop(id: request.id!); objectWillChange.send()
                completion(.init(success: true, activeIDs: activeIDs)); return
            }
            guard !isPending, !otherApprovalPending() else { throw BrowserSessionError.busy }
            if request.action == .list {
                completion(.init(success: true, sessions: try store.list(), activeIDs: activeIDs)); return
            }
            let summary: BrowserSessionSummary
            if let snapshot = request.snapshot {
                try runtime.validate(snapshot)
                summary = .init(snapshot: snapshot, createdAt: now())
            } else {
                guard let found = try store.list().first(where: { $0.id == request.id }) else { throw BrowserSessionError.notFound }
                summary = found
            }
            let ticket = UUID()
            pending = Pending(ticket: ticket, request: request, deadline: now().addingTimeInterval(90),
                              connected: isConnected, completion: completion)
            isPending = true
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.expireIfNeeded() }
            }
            // "Background OK" means exactly that for opening a window it already covers. Saving
            // and deleting still ask: those change what exists, not just what is used.
            if request.action == .open, summary.security == .standard {
                humanApprovedOpen = false
                resolve(approved: true)
                return
            }
            // A standing permission this caller was already given, for this login only.
            if request.action == .open, let fingerprint,
               let approval = try? approvals.valid(sessionId: summary.id, fingerprint: fingerprint, now: now()) {
                try? approvals.noteUse(id: approval.id, field: nil, now: now())
                humanApprovedOpen = false
                resolve(approved: true)
                return
            }
            pendingFingerprint = fingerprint
            humanApprovedOpen = true
            let displayCaller = CallerStatedReason.printableLine(caller, limit: 120)
            // Handing a login to an agent should work the way handing it a key does: once, for an
            // hour, or until revoked — remembered for this caller and this login only. Saving and
            // deleting still ask every time, and an unidentified caller only ever gets "once".
            if request.action == .open, let presentWithDuration, let fingerprint,
               GrantIssuancePolicy.mayRemember(subjectFingerprint: fingerprint) {
                presentWithDuration(.init(action: request.action, session: summary, caller: displayCaller,
                                          offersDurations: true)) { [weak self] duration in
                    guard let self, self.pending?.ticket == ticket else { return }
                    if let duration {
                        self.remember(duration, sessionId: summary.id, fingerprint: fingerprint, caller: displayCaller)
                    }
                    self.resolve(approved: duration != nil)
                }
                return
            }
            present(.init(action: request.action, session: summary, caller: displayCaller)) { [weak self] approved in
                guard self?.pending?.ticket == ticket else { return }
                self?.resolve(approved: approved)
            }
        } catch {
            let code = error as? BrowserSessionError ?? .unavailable
            errorCode = code
            completion(.init(success: false, errorCode: code))
        }
    }

    /// A login the person just did in KeyKeeper's own window. The click that ends it is the
    /// approval: there is no caller to vouch for, and a prompt asking them to confirm what they
    /// themselves just did would be noise.
    func saveLocalLogin(_ snapshot: BrowserSessionImport) throws {
        _ = try store.save(snapshot, now: now())
        refresh()
    }

    func expireIfNeeded() {
        guard let pending else { return }
        if !pending.connected() { finish(.init(success: false, errorCode: .disconnected)) }
        else if now() >= pending.deadline { finish(.init(success: false, errorCode: .expired)) }
    }

    private func resolve(approved: Bool) {
        expireIfNeeded()
        guard let pending else { return }
        guard approved else { finish(.init(success: false, errorCode: .denied)); return }
        do {
            switch pending.request.action {
            case .save:
                let summary = try store.save(pending.request.snapshot!, now: now())
                finish(.init(success: true, sessions: [summary]))
            case .delete:
                runtime.stop(id: pending.request.id!)
                try store.delete(id: pending.request.id!)
                // What was given to it goes with it: a new snapshot under the same id inherits nothing.
                try? approvals.revokeAll(forSession: pending.request.id!)
                finish(.init(success: true))
            case .open:
                let id = pending.request.id!
                guard !activeIDs.contains(id) else { throw BrowserSessionError.busy }
                try store.withSnapshot(id: id, now: now()) { snapshot in
                    openingID = id
                    runtime.open(snapshot, bringToFront: humanApprovedOpen) { [weak self] opened in
                        guard let self, self.pending?.ticket == pending.ticket else { return }
                        self.expireIfNeeded()
                        guard self.pending?.ticket == pending.ticket else { return }
                        if opened { self.openingID = nil }
                        self.finish(.init(success: opened, activeIDs: self.activeIDs, errorCode: opened ? nil : .unavailable))
                    }
                }
            case .list, .stop: throw BrowserSessionError.invalidImport
            }
        } catch { finish(.init(success: false, errorCode: error as? BrowserSessionError ?? .unavailable)) }
    }

    func stopAll() {
        finish(.init(success: false, errorCode: .denied)); runtime.stopAll(); objectWillChange.send()
    }

    private func finish(_ response: BrowserSessionResponse) {
        guard let pending else { return }
        self.pending = nil; isPending = false; timer?.invalidate(); timer = nil
        if let id = openingID { runtime.stop(id: id); openingID = nil }
        dismiss(); errorCode = response.errorCode
        if response.success { refresh() }
        pending.completion(response)
    }
}
