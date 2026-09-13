import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

private final class BrowserTestIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var writes = 0
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data; writes += 1 }
}

@MainActor final class BrowserImportBridgeTests: XCTestCase {
    private var directory: URL!
    private var meta: MetaStore!
    private var io: BrowserTestIO!
    private var service: KeychainCredentialService!
    private var controller: ClipboardSaveController!
    private var bridge: BrowserImportBridge!
    private var url: URL!
    private var results: [ClipboardSaveResponse] = []
    private var decision: ((Bool) -> Void)?
    private var clock = Date()
    private var connected = true

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("browser-import-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        meta = MetaStore(directory: directory); io = BrowserTestIO()
        service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.meta.load() }))
        controller = ClipboardSaveController(service: service, metaStore: meta, now: { self.clock },
            present: { _, decide in self.decision = decide }, dismiss: {})
        bridge = BrowserImportBridge(controller: controller)
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
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(url); XCTAssertTrue(controller.isPending); XCTAssertNil(decision)
    }
    private func post(cancel: Bool = false, ticket: String? = nil) -> URLRequest {
        var target = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let authorization = ticket ?? target.fragment!; target.fragment = nil; target.path = "/import"
        var request = URLRequest(url: target.url!)
        request.httpMethod = "POST"; request.httpBody = Data("synthetic-browser".utf8)
        request.setValue("http://127.0.0.1:\(url.port!)", forHTTPHeaderField: "Origin")
        request.setValue("text/plain;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(authorization, forHTTPHeaderField: "X-KeyKeeper-Session")
        if cancel { request.setValue("1", forHTTPHeaderField: "X-KeyKeeper-Cancel") }
        request.timeoutInterval = 4
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
        decision?(true)
        let (body, _) = try await submission.value
        let saved = try JSONDecoder().decode(ClipboardSaveResponse.self, from: body)
        XCTAssertEqual(saved.success, true)
        // 形状可以回（长度、是否 Base64），值永远不回。粘贴页本来就持有这个值，回形状不扩大暴露面。
        XCTAssertEqual(saved.shape, ValueShape.of("synthetic-browser"))
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
    func testBrowserDisconnectCancelsPendingApprovalAndCannotSaveLater() async throws {
        try await start()
        let submission = Task { try await URLSession.shared.data(for: post()) }
        for _ in 0..<150 {
            if decision != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(decision)
        submission.cancel()
        _ = try? await submission.value
        for _ in 0..<150 {
            if !controller.isPending { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(results.last?.errorCode, .disconnected)
        decision?(true); XCTAssertEqual(io.writes, 0)
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
        let (data, _) = try await submission.value
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSaveResponse.self, from: data).errorCode, .denied)
        XCTAssertEqual(io.writes, 0)
        decision = nil; bridge = BrowserImportBridge(controller: controller)
        try await start()
        oldBridge?.cancel()
        XCTAssertTrue(controller.isPending)
        controller.cancel()
    }
    func testExpireAndDisconnectedCLIReleaseReservationWithoutSaving() async throws {
        try await start(); clock.addTimeInterval(91); controller.expireIfNeeded()
        XCTAssertEqual(results.last?.errorCode, .expired); XCTAssertEqual(io.writes, 0)
        bridge = BrowserImportBridge(controller: controller)
        try await start(); connected = false; controller.expireIfNeeded()
        XCTAssertEqual(results.last?.errorCode, .disconnected); XCTAssertEqual(io.writes, 0)
    }
}
