import Foundation
import KeyKeeperCore

@MainActor protocol BrowserSessionRuntime: AnyObject {
    var activeIDs: [String] { get }
    func validate(_ snapshot: BrowserSessionImport) throws
    func open(_ snapshot: BrowserSessionImport, completion: @escaping (Bool) -> Void)
    func stop(id: String)
    func stopAll()
}

extension BrowserSessionRuntime { func validate(_ snapshot: BrowserSessionImport) throws {} }

struct BrowserSessionPresentation {
    let action: BrowserSessionRequest.Action
    let session: BrowserSessionSummary
    let caller: String
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
    var activeIDs: [String] { runtime.activeIDs }

    init(store: BrowserSessionStore, runtime: BrowserSessionRuntime, now: @escaping () -> Date = Date.init,
         present: @escaping (BrowserSessionPresentation, @escaping (Bool) -> Void) -> Void,
         dismiss: @escaping () -> Void) {
        self.store = store; self.runtime = runtime; self.now = now; self.present = present; self.dismiss = dismiss
    }

    func refresh() {
        do { sessions = try store.list(); errorCode = nil }
        catch { sessions = []; errorCode = .unavailable }
    }

    func receive(_ request: BrowserSessionRequest, caller: String, isConnected: @escaping () -> Bool = { true },
                 completion: @escaping (BrowserSessionResponse) -> Void) {
        do {
            try request.validate()
            guard isConnected() else { throw BrowserSessionError.disconnected }
            if request.action == .stop {
                if openingID == request.id || (pending?.request.action == .open && pending?.request.id == request.id) {
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
            let displayCaller = String(caller.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(120))
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
                finish(.init(success: true))
            case .open:
                let id = pending.request.id!
                guard !activeIDs.contains(id) else { throw BrowserSessionError.busy }
                try store.withSnapshot(id: id, now: now()) { snapshot in
                    openingID = id
                    runtime.open(snapshot) { [weak self] opened in
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
