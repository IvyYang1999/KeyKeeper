import Foundation
import Network
import Security
import KeyKeeperCore

@MainActor private final class BrowserPasteSource: ClipboardSaveSource {
    let changeCount = 0
    var text: String?
    func readText() -> String? { text }
    func clearIfUnchanged(since count: Int) { text = nil }
}

/// One listener per bounded import. The CLI owns its lifetime; no standing HTTP write API.
@MainActor final class BrowserImportBridge {
    private final class Peer {
        let connection: NWConnection
        var bytes = Data()
        var timeout: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let controller: ClipboardSaveController
    private let proposalStore: BrowserImportProposalStore
    private let now: () -> Date
    private let source = BrowserPasteSource()
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var active = false
    private var submitted = false
    private var ticket = ""
    private var host = ""
    private var page = ""
    private var completion: ((ClipboardSaveResponse) -> Void)?
    private(set) var snapshot = BrowserImportProposalSnapshot(
        id: String(repeating: "0", count: 64), credentialId: "", fieldName: "",
        state: .failed, nextAction: nil, errorCode: .storageUnavailable)

    init(controller: ClipboardSaveController, proposalStore: BrowserImportProposalStore,
         now: @escaping () -> Date = Date.init) {
        self.controller = controller
        self.proposalStore = proposalStore
        self.now = now
    }

    func cancel() { if active, !snapshot.state.isTerminal { controller.cancel() } }

    func suspendForTermination() -> Bool {
        guard active, [.pasteReceived, .approvalVisible, .committing].contains(snapshot.state) else { return false }
        return controller.suspendRecoverableForTermination()
    }
    func shutdown() {
        active = false; listener?.cancel(); listener = nil
        for id in Array(peers.keys) { lost(id) }
        source.text = nil; ticket = ""; page = ""
        startedRequest = nil; startedCallerName = nil
    }

    func reopen() {
        guard active, [.pasteReceived, .approvalVisible].contains(snapshot.state) else { return }
        do {
            try persistState(.approvalVisible, deadline: controller.pendingDeadline,
                             nextAction: "Approve or cancel in KeyKeeper.")
            controller.reopenPending()
        } catch {
            controller.fail(.storageUnavailable)
        }
    }

    /// Reconstructs a pasted-but-unfinished proposal after the App process restarted. It never
    /// presents or approves by itself: `proposal open` remains the explicit user action.
    @discardableResult
    func recover(_ record: BrowserImportProposalRecord) -> Bool {
        guard !active, !controller.isPending,
              !record.snapshot.state.isTerminal,
              let request = record.request,
              let callerName = record.callerName,
              let candidate = record.candidate,
              let metadataFingerprint = record.metadataFingerprint,
              let deadline = record.snapshot.deadline else { return false }
        active = true
        submitted = true
        snapshot = record.snapshot
        source.text = candidate
        if now() >= deadline {
            finish(.init(success: false, errorCode: .expired))
            return false
        }
        controller.receive(
            request, callerName: callerName, isConnected: { true }, source: source,
            deferPresentation: true, expiresAfter: deadline.timeIntervalSince(now()),
            survivesDisconnect: true,
            willCommit: { [weak self] in try self?.markCommitting() },
            completion: { [weak self] in self?.finish($0) }
        )
        guard let context = controller.recoveryContext() else { return false }
        guard context.metadataFingerprint == metadataFingerprint else {
            controller.fail(.metadataChanged)
            return false
        }
        guard context.targetValueFingerprint == record.targetValueFingerprint else {
            controller.fail(.targetValueChanged)
            return false
        }
        do {
            try persistState(.pasteReceived, deadline: deadline,
                             nextAction: "Run keykeeper proposal open to approve or cancel in KeyKeeper.")
            return true
        } catch {
            controller.fail(.storageUnavailable)
            return false
        }
    }

    func start(_ request: ClipboardSaveRequest, callerName: String, isConnected: @escaping () -> Bool,
               ready: @escaping (String) -> Void, completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard !active, !controller.isPending else { completion(.init(success: false, errorCode: .busy)); return }
        active = true; self.completion = completion
        startedRequest = request; startedCallerName = callerName
        do {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw BrowserImportHTTP.Rejected.invalid
            }
            ticket = random.map { String(format: "%02x", $0) }.joined()
            snapshot = .init(id: BrowserImportProposalID.fromTicket(ticket),
                credentialId: request.credentialId, fieldName: request.fieldName,
                state: .receiverReady, nextAction: "Open the local receiver and paste the value.")
            page = BrowserImportPage.html(request: request)
            controller.receive(request, callerName: callerName,
                isConnected: isConnected, source: source, deferPresentation: true,
                expiresAfter: nil, survivesDisconnect: true,
                willCommit: { [weak self] in try self?.markCommitting() },
                completion: { [weak self] in self?.finish($0) })
            guard controller.isPending else { return }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.active else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener?.port else { self.controller.cancel(); return }
                        self.host = "127.0.0.1:\(port.rawValue)"
                        self.controller.armDeadline(after: 90)
                        self.setState(.receiverReady, deadline: self.controller.pendingDeadline,
                                      nextAction: "Open the local receiver and paste the value.")
                        ready("http://\(self.host)/#\(self.ticket)")
                    case .failed: self.controller.cancel()
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { controller.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard active, peers.count < 4 else { connection.cancel(); return }
        let id = UUID(), peer = Peer(connection)
        peers[id] = peer
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { Task { @MainActor in self?.lost(id) } }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.lost(id) }
        peer.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
        connection.start(queue: .main)
        receive(id)
    }

    private func receive(_ id: UUID) {
        guard let peer = peers[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in self?.received(id, data: data, done: done, failed: error != nil) }
        }
    }

    private func received(_ id: UUID, data: Data?, done: Bool, failed: Bool) {
        guard active, let peer = peers[id] else { return }
        if let data { peer.bytes.append(data) }
        do {
            if let request = try BrowserImportHTTP.parse(peer.bytes, host: host, ticket: ticket) {
                peer.bytes.removeAll(keepingCapacity: false); peer.timeout?.cancel()
                if request.path == "/" {
                    respond(id, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
                } else if request.path == "/status" {
                    respondJSON(id, status: 200, snapshot)
                } else if request.path == "/cancel" {
                    guard !snapshot.state.isTerminal else { throw BrowserImportHTTP.Rejected.invalid }
                    respondJSON(id, status: 200, snapshot)
                    controller.cancel()
                } else {
                    guard request.path == "/import", !submitted, !failed, !done,
                          !snapshot.state.isTerminal else { throw BrowserImportHTTP.Rejected.invalid }
                    submitted = true
                    guard let text = String(data: request.body, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserImportHTTP.Rejected.invalid }
                    source.text = text
                    controller.armDeadline(after: 10 * 60)
                    setState(.pasteReceived, deadline: controller.pendingDeadline,
                             nextAction: "Approve or cancel in KeyKeeper.")
                    guard let context = controller.recoveryContext(), let deadline = controller.pendingDeadline else {
                        controller.fail(.storageUnavailable)
                        throw BrowserImportHTTP.Rejected.invalid
                    }
                    guard let startedRequest, let startedCallerName else {
                        controller.fail(.storageUnavailable)
                        throw BrowserImportHTTP.Rejected.invalid
                    }
                    do {
                        let timestamp = now()
                        try proposalStore.stage(.init(
                            snapshot: snapshot,
                            request: startedRequest,
                            callerName: startedCallerName,
                            candidate: text,
                            metadataFingerprint: context.metadataFingerprint,
                            targetValueFingerprint: context.targetValueFingerprint,
                            createdAt: timestamp,
                            updatedAt: timestamp
                        ))
                    } catch {
                        controller.fail(.storageUnavailable)
                        throw BrowserImportHTTP.Rejected.invalid
                    }
                    respondJSON(id, status: 202, snapshot)
                    if !snapshot.state.isTerminal {
                        do {
                            try persistState(.approvalVisible, deadline: deadline,
                                             nextAction: "Approve or cancel in KeyKeeper.")
                            controller.presentPending()
                        } catch {
                            controller.fail(.storageUnavailable)
                        }
                    }
                }
                return
            }
            if failed || done { lost(id) } else { receive(id) }
        } catch {
            respond(id, status: 400, type: "application/json", body: Data("{\"success\":false}".utf8))
        }
    }

    private func lost(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.bytes.removeAll(keepingCapacity: false); peer.connection.cancel()
    }

    private func respondJSON<T: Encodable>(_ id: UUID, status: Int, _ value: T) {
        let body = (try? JSONEncoder().encode(value)) ?? Data("{\"success\":false}".utf8)
        respond(id, status: status, type: "application/json", body: body)
    }

    private func respond(_ id: UUID, status: Int, type: String, body: Data) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.bytes.removeAll(keepingCapacity: false)
        let reason = status == 200 ? "OK" : status == 202 ? "Accepted" : "Bad Request"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n"
        let connection = peer.connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ response: ClipboardSaveResponse) {
        guard active, !snapshot.state.isTerminal else { return }
        let state: BrowserImportProposalState
        if response.success { state = .committed }
        else if response.errorCode == .expired { state = .expired }
        else if response.errorCode == .denied { state = .cancelled }
        else { state = .failed }
        setState(state, deadline: nil, nextAction: nil, errorCode: response.errorCode)
        source.text = nil
        try? proposalStore.finish(id: snapshot.id, snapshot: snapshot, now: now())
        let callback = completion; completion = nil; callback?(response)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10 * 60) { [weak self] in self?.shutdown() }
    }

    private func setState(_ state: BrowserImportProposalState, deadline: Date? = nil,
                          nextAction: String?, errorCode: ClipboardSaveError? = nil) {
        snapshot.state = state
        snapshot.deadline = deadline
        snapshot.nextAction = nextAction
        snapshot.errorCode = errorCode
    }

    private var startedRequest: ClipboardSaveRequest?
    private var startedCallerName: String?

    private func markCommitting() throws {
        try persistState(.committing, deadline: controller.pendingDeadline,
                         nextAction: "Wait for KeyKeeper to finish the local write.")
    }

    private func persistState(_ state: BrowserImportProposalState, deadline: Date?, nextAction: String?) throws {
        var updated = snapshot
        updated.state = state
        updated.deadline = deadline
        updated.nextAction = nextAction
        updated.errorCode = nil
        try proposalStore.update(id: updated.id, snapshot: updated, now: now())
        snapshot = updated
    }
}
