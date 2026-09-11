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
        var waiting = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let controller: ClipboardSaveController
    private let source = BrowserPasteSource()
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var active = false
    private var submitted = false
    private var acceptedCount = 0
    private var browserConnected = true
    private var ticket = ""
    private var host = ""
    private var page = ""
    private var completion: ((ClipboardSaveResponse) -> Void)?

    init(controller: ClipboardSaveController) { self.controller = controller }

    func cancel() { if active { controller.cancel() } }

    func start(_ request: ClipboardSaveRequest, callerName: String, isConnected: @escaping () -> Bool,
               ready: @escaping (String) -> Void, completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard !active, !controller.isPending else { completion(.init(success: false, errorCode: .busy)); return }
        active = true; self.completion = completion
        controller.receive(request, callerName: callerName,
            isConnected: { [weak self] in self?.browserConnected == true && isConnected() },
            source: source, deferPresentation: true, completion: { [weak self] in self?.finish($0) })
        guard active else { return }
        do {
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
                throw BrowserImportHTTP.Rejected.invalid
            }
            ticket = random.map { String(format: "%02x", $0) }.joined()
            page = BrowserImportPage.html(request: request)
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
        guard active, peers.count < 4, acceptedCount < 32 else { connection.cancel(); return }
        acceptedCount += 1
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
        if peer.waiting {
            // A closed browser or extra request bytes invalidate its pending approval.
            lost(id); return
        }
        if let data { peer.bytes.append(data) }
        var ownsSubmission = false
        do {
            if let request = try BrowserImportHTTP.parse(peer.bytes, host: host, ticket: ticket) {
                peer.bytes.removeAll(keepingCapacity: false); peer.timeout?.cancel()
                if request.method == "GET" {
                    respond(id, status: 200, type: "text/html; charset=utf-8", body: Data(page.utf8))
                } else {
                    guard !submitted, !failed, !done else { throw BrowserImportHTTP.Rejected.invalid }
                    submitted = true
                    ownsSubmission = true
                    if request.cancel {
                        respond(id, status: 200, type: "application/json", body: Data("{\"success\":false}".utf8))
                        controller.cancel(); return
                    }
                    guard let text = String(data: request.body, encoding: .utf8),
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BrowserImportHTTP.Rejected.invalid }
                    source.text = text; peer.waiting = true
                    receive(id)
                    controller.presentPending()
                }
                return
            }
            if failed || done { lost(id) } else { receive(id) }
        } catch {
            respond(id, status: 400, type: "application/json", body: Data("{\"success\":false}".utf8))
            if ownsSubmission { controller.cancel() }
        }
    }

    private func lost(_ id: UUID) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.bytes.removeAll(keepingCapacity: false); peer.connection.cancel()
        if peer.waiting { browserConnected = false; controller.expireIfNeeded() }
    }

    private func respond(_ id: UUID, status: Int, type: String, body: Data) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.bytes.removeAll(keepingCapacity: false)
        let headers = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n"
        let connection = peer.connection
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { connection.cancel() }
        connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func finish(_ response: ClipboardSaveResponse) {
        guard active else { return }
        active = false; listener?.cancel(); listener = nil; source.text = nil; ticket = ""; page = ""
        let body = (try? JSONEncoder().encode(response)) ?? Data("{\"success\":false}".utf8)
        for id in Array(peers.keys) {
            if peers[id]?.waiting == true { respond(id, status: 200, type: "application/json", body: body) }
            else { lost(id) }
        }
        let callback = completion; completion = nil; callback?(response)
    }
}
