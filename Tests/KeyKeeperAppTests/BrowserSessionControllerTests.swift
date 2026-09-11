import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor final class BrowserSessionControllerTests: XCTestCase {
    func testDenyDisconnectAndExpiryNeverSaveAndApprovalIsSingleUse() throws {
        let io = SessionControllerIO(), runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var now = Date(); var connected = true; var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { now },
            present: { _, reply in decide = reply }, dismiss: {})
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        var result: BrowserSessionResponse?
        func receive() { controller.receive(.init(action: .save, snapshot: input), caller: "Fixture", isConnected: { connected }) { result = $0 } }
        receive(); XCTAssertNil(io.blob); decide?(false)
        XCTAssertEqual(result?.errorCode, .denied); XCTAssertNil(io.blob)
        receive(); connected = false; decide?(true)
        XCTAssertEqual(result?.errorCode, .disconnected); XCTAssertNil(io.blob)
        connected = true; receive(); now = now.addingTimeInterval(91); decide?(true)
        XCTAssertEqual(result?.errorCode, .expired); XCTAssertNil(io.blob)
        receive(); let oldDecision = decide; decide?(true)
        XCTAssertEqual(result?.success, true); XCTAssertEqual(io.writes, 1)
        oldDecision?(true); XCTAssertEqual(io.writes, 1)
        XCTAssertEqual(runtime.openCount, 0)
    }

    func testConcurrentAndExternalApprovalBusyRequestsCannotReplacePendingIntent() {
        let controller = BrowserSessionController(store: .init(io: SessionControllerIO(), marker: SessionControllerMarker()),
            runtime: TestSessionRuntime(), present: { _, _ in }, dismiss: {})
        controller.otherApprovalPending = { true }
        var result: BrowserSessionResponse?
        controller.receive(.init(action: .open, id: UUID().uuidString), caller: "Fixture") { result = $0 }
        XCTAssertEqual(result?.errorCode, .busy)
        XCTAssertEqual(controller.errorCode, .busy)
        XCTAssertFalse(controller.isPending)
    }

    func testStopCancelsPendingOpenAndLateApprovalCannotReopen() throws {
        let runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: SessionControllerIO(), marker: SessionControllerMarker())
        let snapshot = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        try store.save(snapshot)
        var approve: ((Bool) -> Void)?; var result: BrowserSessionResponse?
        let controller = BrowserSessionController(store: store, runtime: runtime,
            present: { _, reply in approve = reply }, dismiss: {})
        controller.receive(.init(action: .open, id: snapshot.id), caller: "Synthetic") { result = $0 }
        XCTAssertTrue(controller.isPending); XCTAssertEqual(runtime.openCount, 0)
        controller.receive(.init(action: .stop, id: snapshot.id), caller: "Synthetic") { XCTAssertTrue($0.success) }
        approve?(true)
        XCTAssertEqual(result?.errorCode, .denied); XCTAssertEqual(runtime.openCount, 0)
        controller.receive(.init(action: .open, id: snapshot.id), caller: "Synthetic") { result = $0 }
        approve?(true)
        XCTAssertEqual(runtime.activeIDs, [snapshot.id]); XCTAssertTrue(result!.success)
        controller.receive(.init(action: .delete, id: snapshot.id), caller: "Synthetic") { result = $0 }
        XCTAssertEqual(try store.list().count, 1)
        approve?(false); XCTAssertEqual(try store.list().count, 1)
        controller.receive(.init(action: .delete, id: snapshot.id), caller: "Synthetic") { result = $0 }
        approve?(true)
        XCTAssertTrue(try store.list().isEmpty); XCTAssertTrue(runtime.activeIDs.isEmpty)
    }
}

private final class SessionControllerIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?; var writes = 0
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data; writes += 1 }
}
private final class SessionControllerMarker: BrowserSessionMarker {
    var exists = false
    func wasCreated() throws -> Bool { exists }
    func markCreated() throws { exists = true }
}
@MainActor private final class TestSessionRuntime: BrowserSessionRuntime {
    var activeIDs: [String] = []; var openCount = 0
    func open(_ snapshot: BrowserSessionImport, completion: @escaping (Bool) -> Void) {
        openCount += 1; activeIDs.append(snapshot.id); completion(true)
    }
    func stop(id: String) { activeIDs.removeAll { $0 == id } }
    func stopAll() { activeIDs = [] }
}
