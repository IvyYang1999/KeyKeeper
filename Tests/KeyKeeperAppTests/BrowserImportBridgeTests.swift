import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp
import KeyKeeperTestSupport

private final class BridgeProposalMarker: BrowserImportProposalMarker, @unchecked Sendable {
    var created = false
    func wasCreated() throws -> Bool { created }
    func markCreated() throws { created = true }
}

@MainActor final class BrowserImportBridgeTests: XCTestCase {
    private var directory: URL!
    private var meta: MetaStore!
    private var io: FakeKeychainIO!
    private var service: KeychainCredentialService!
    private var controller: ClipboardSaveController!
    private var bridge: BrowserImportBridge!
    private var proposalStore: BrowserImportProposalStore!
    private var proposalMarker: BridgeProposalMarker!
    private var proposalIO: FakeKeychainIO!
    private var url: URL!
    private var results: [ClipboardSaveResponse] = []
    private var decision: ((Bool) -> Void)?
    private var clock = Date()
    private var connected = true

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-import-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        meta = MetaStore(directory: directory); io = FakeKeychainIO()
        service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.meta.load() }))
        proposalMarker = BridgeProposalMarker()
        proposalIO = io.keychain.io("com.keykeeper.test.browser-import-proposals")
        proposalStore = BrowserImportProposalStore(io: proposalIO, marker: proposalMarker)
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), now: { self.clock },
            present: { _, decide in self.decision = decide }, dismiss: {})
        bridge = BrowserImportBridge(controller: controller, proposalStore: proposalStore, now: { self.clock })
        connected = true; results = []; decision = nil; clock = Date()
    }
    override func tearDownWithError() throws {
        controller.cancel(); decision = nil; bridge = nil; controller = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func start() async throws {
        let ready = expectation(description: "loopback ready")
        bridge.start(.init(credentialId: "fixture", fieldName: "key", create: true), callerName: "Synthetic test",
            isConnected: { self.connected }, ready: { self.url = URL(string: $0); ready.fulfill() },
            completion: { self.results.append($0) })
        XCTAssertNil(controller.pendingDeadline, "The receiver lifetime must start only after the listener is usable")
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(url); XCTAssertTrue(controller.isPending); XCTAssertNil(decision)
        XCTAssertEqual(controller.pendingDeadline, clock.addingTimeInterval(90))
    }
    private func post(cancel: Bool = false, ticket: String? = nil) -> URLRequest {
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let authorization = ticket ?? target.fragment!; target.fragment = nil; target.path = cancel ? "/cancel" : "/import"
        var request = URLRequest(url: target.url!)
        request.httpMethod = "POST"; request.httpBody = Data("synthetic-browser".utf8)
        request.setValue("http://127.0.0.1:\(url.port!)", forHTTPHeaderField: "Origin")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "X-KeyKeeper-Session")
        request.timeoutInterval = 4
        return request
    }
    private func status() -> URLRequest {
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let authorization = target.fragment!; target.fragment = nil; target.path = "/status"
        var request = URLRequest(url: target.url!)
        request.httpMethod = "POST"; request.httpBody = Data("status".utf8)
        request.setValue("http://127.0.0.1:\(url.port!)", forHTTPHeaderField: "Origin")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "X-KeyKeeper-Session")
        return request
    }
    func testRealHTTPRequiresApprovalAndReturnsOnlyConstantResult() async throws {
        try await start()
        let (html, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let page = String(decoding: html, as: UTF8.self)
        XCTAssertFalse(page.contains(url.fragment!)); XCTAssertTrue(page.contains("e.preventDefault()"))
        let presented = expectation(description: "native approval")
        let submission = Task { try await URLSession.shared.data(for: post()) }
        // Wait for the real HTTP request to reach the native presentation seam, bounded at 3 seconds.
        for _ in 0..<150 {
            if decision != nil { presented.fulfill(); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        await fulfillment(of: [presented], timeout: 0.1)
        XCTAssertEqual(io.writes, 0)
        let (_, replay) = try await URLSession.shared.data(for: post())
        XCTAssertEqual((replay as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertTrue(controller.isPending, "A rejected replay must not cancel the original approval")
        let (accepted, acceptedResponse) = try await submission.value
        XCTAssertEqual((acceptedResponse as? HTTPURLResponse)?.statusCode, 202)
        XCTAssertEqual(try JSONDecoder().decode(BrowserImportProposalSnapshot.self, from: accepted).state, .pasteReceived)
        XCTAssertEqual(controller.pendingDeadline, clock.addingTimeInterval(10 * 60))
        decision?(true)
        let (body, _) = try await URLSession.shared.data(for: status())
        let saved = try JSONDecoder().decode(BrowserImportProposalSnapshot.self, from: body)
        XCTAssertEqual(saved.state, .committed)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("synthetic-browser"))
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-browser")
        XCTAssertEqual(try meta.load().credentials["fixture"]?.security, .strict)
        XCTAssertEqual(io.writes, 1)
        decision?(true); XCTAssertEqual(io.writes, 1)
    }
    func testWrongTicketDoesNotShowApprovalAndCancelWritesNothing() async throws {
        try await start()
        let (_, denied) = try await URLSession.shared.data(for: post(ticket: "wrong"))
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 400)
        XCTAssertNil(decision); XCTAssertTrue(controller.isPending)
        _ = try await URLSession.shared.data(for: post(cancel: true))
        XCTAssertEqual(results.last?.errorCode, .denied); XCTAssertEqual(io.writes, 0)
    }
    func testBrowserAndCLIDisconnectAfterPasteKeepProposalRecoverable() async throws {
        try await start()
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision)
        connected = false
        submission.cancel()
        _ = try? await submission.value
        controller.expireIfNeeded()
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(bridge.snapshot.state, .approvalVisible)
        bridge.reopen()
        decision?(true)
        XCTAssertEqual(io.writes, 1)
        XCTAssertEqual(bridge.snapshot.state, .committed)
    }
    func testNativeDenialAfterPasteAndExpiredBridgeCannotCancelNewRequest() async throws {
        try await start()
        let oldBridge = bridge
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision); decision?(false)
        _ = try await submission.value
        let (data, _) = try await URLSession.shared.data(for: status())
        XCTAssertEqual(try JSONDecoder().decode(BrowserImportProposalSnapshot.self, from: data).state, .cancelled)
        XCTAssertEqual(io.writes, 0)
        decision = nil
        bridge = BrowserImportBridge(controller: controller, proposalStore: proposalStore, now: { self.clock })
        try await start()
        oldBridge?.cancel()
        XCTAssertTrue(controller.isPending)
        controller.cancel()
    }
    func testReceiverExpiresButDisconnectedCLIDoesNotCancelProposal() async throws {
        try await start(); clock.addTimeInterval(91); controller.expireIfNeeded()
        XCTAssertEqual(results.last?.errorCode, .expired); XCTAssertEqual(io.writes, 0)
        bridge = BrowserImportBridge(controller: controller, proposalStore: proposalStore, now: { self.clock })
        let completedCount = results.count
        try await start(); connected = false; controller.expireIfNeeded()
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(results.count, completedCount, "Closing the original CLI is not a proposal decision")
        XCTAssertEqual(io.writes, 0)
    }

    func testPastedProposalSurvivesAppRestartAndCommitsWithoutAnotherPaste() async throws {
        try await start()
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision)
        _ = try await submission.value
        let proposalID = bridge.snapshot.id
        XCTAssertEqual(try proposalStore.record(id: proposalID)?.candidate, "synthetic-browser")

        // Simulate process death: no denial callback and no cleanup gets to run.
        XCTAssertTrue(bridge.suspendForTermination())
        decision = nil
        let reopenedStore = BrowserImportProposalStore(
            io: io.keychain.io("com.keykeeper.test.browser-import-proposals"), marker: proposalMarker)
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), now: { self.clock },
            present: { _, decide in self.decision = decide }, dismiss: {})
        bridge = BrowserImportBridge(controller: controller, proposalStore: reopenedStore, now: { self.clock })
        let record = try XCTUnwrap(reopenedStore.record(id: proposalID))

        XCTAssertTrue(bridge.recover(record))
        XCTAssertEqual(bridge.snapshot.state, .pasteReceived)
        XCTAssertNil(decision, "Recovery must not approve or show a stale window by itself")
        bridge.reopen()
        XCTAssertNotNil(decision)
        decision?(true)

        XCTAssertEqual(bridge.snapshot.state, .committed)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-browser")
        XCTAssertNil(try reopenedStore.record(id: proposalID)?.candidate)
    }

    func testRecoveryRejectsMetadataChangedWhileAppWasStoppedAndScrubsCandidate() async throws {
        try await start()
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision)
        _ = try await submission.value
        let proposalID = bridge.snapshot.id

        var changed = try meta.load()
        changed.credentials["unrelated"] = Credential(label: "unrelated", notes: "", links: [], fields: [:],
                                                        security: .strict, created: "", updated: "")
        try meta.save(changed)
        decision = nil
        let reopenedStore = BrowserImportProposalStore(
            io: io.keychain.io("com.keykeeper.test.browser-import-proposals"), marker: proposalMarker)
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), now: { self.clock },
            present: { _, decide in self.decision = decide }, dismiss: {})
        bridge = BrowserImportBridge(controller: controller, proposalStore: reopenedStore, now: { self.clock })

        XCTAssertFalse(bridge.recover(try XCTUnwrap(reopenedStore.record(id: proposalID))))
        XCTAssertEqual(bridge.snapshot.state, .failed)
        XCTAssertEqual(bridge.snapshot.errorCode, .metadataChanged)
        XCTAssertNil(try reopenedStore.record(id: proposalID)?.candidate)
        XCTAssertNil(decision)
        XCTAssertEqual(io.writes, 0)
    }

    func testCommitJournalFailureStopsBeforeCredentialWrite() async throws {
        try await start()
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision)
        _ = try await submission.value
        proposalIO.failWrites = true

        decision?(true)

        XCTAssertEqual(bridge.snapshot.state, .failed)
        XCTAssertEqual(bridge.snapshot.errorCode, .storageUnavailable)
        XCTAssertEqual(io.writes, 0, "A missing committing journal entry must stop before the credential vault")
        XCTAssertThrowsError(try service.retrieve(credentialId: "fixture", fieldName: "key"))
    }
}
