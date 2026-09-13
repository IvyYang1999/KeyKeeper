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

    /// yyt 2026-09-13：「到期不是砍掉窗口，是重新要一次授权」，做法是冻结 + 覆盖层。
    /// 到期时窗口会回头问控制器：这一次要不要打扰人。答案取决于这条登录态自己的安全级别，
    /// 和 key 是同一个规矩。
    func test到期重新授权按登录态自己的级别决定要不要问() throws {
        let io = SessionControllerIO(), runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var prompts = 0; var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in prompts += 1; decide = reply }, dismiss: {})
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        controller.refresh()

        // 默认「每次询问」：到期要问，答应了才继续
        var granted: Bool?
        runtime.reauthorize?(input.id, { granted = $0 })
        XCTAssertEqual(prompts, 1)
        XCTAssertNil(granted, "没点之前不能替人答应")
        decide?(true)
        XCTAssertEqual(granted, true)

        // 拒绝就是拒绝——窗口那边会据此关掉
        granted = nil
        runtime.reauthorize?(input.id, { granted = $0 })
        decide?(false)
        XCTAssertEqual(granted, false)

        // 改成「后台放行」之后，到期不该再打扰人
        try store.setSecurity(id: input.id, to: .standard)
        controller.refresh()
        let before = prompts
        granted = nil
        runtime.reauthorize?(input.id, { granted = $0 })
        XCTAssertEqual(prompts, before, "后台放行的登录态到期不该弹窗")
        XCTAssertEqual(granted, true)

        // 不认识的 id 一律拒绝
        granted = nil
        runtime.reauthorize?("not-a-session", { granted = $0 })
        XCTAssertEqual(granted, false)
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
    var reauthorize: ((String, @escaping (Bool) -> Void) -> Void)?
    func setReauthorizationHandler(_ handler: @escaping (String, @escaping (Bool) -> Void) -> Void) {
        reauthorize = handler
    }
    var activeIDs: [String] = []; var openCount = 0
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool, completion: @escaping (Bool) -> Void) {
        openCount += 1; activeIDs.append(snapshot.id); completion(true)
    }
    func stop(id: String) { activeIDs.removeAll { $0 == id } }
    func stopAll() { activeIDs = [] }
}

/// 对抗审计（2026-09-13）：`open` 里无条件 `NSApp.activate(ignoringOtherApps: true)`。
/// 今天每次打开都要真人点一下，所以抢焦点还算合理；一旦「后台放行」上线，一个没人批准的
/// 窗口会突然弹到你面前——你正在打的字就进了一个已登录的页面。
@MainActor final class BrowserSessionFocusTests: XCTestCase {
    func test人点过头的才允许抢焦点() throws {
        let io = SessionControllerIO(), runtime = FocusTrackingRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in decide = reply }, dismiss: {})
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        controller.refresh()

        // 每次询问：人刚刚点了「允许」，窗口该到人面前来
        controller.receive(.init(action: .open, id: input.id), caller: "Fixture") { _ in }
        decide?(true)
        XCTAssertEqual(runtime.lastBringToFront, true)

        // 后台放行：没人点过头，就别抢焦点
        try store.setSecurity(id: input.id, to: .standard)
        controller.refresh()
        runtime.stop(id: input.id)
        controller.receive(.init(action: .open, id: input.id), caller: "Fixture") { _ in }
        XCTAssertEqual(runtime.lastBringToFront, false, "没人批准的窗口不该弹到人脸上")
    }

    /// 有了这个调用方自己的授权，打开就不再问——但只对**这个调用方**、**这条登录态**生效。
    func test已有授权的调用方打开不再弹窗() throws {
        let io = SessionControllerIO(), runtime = FocusTrackingRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var prompts = 0; var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in prompts += 1; decide = reply }, dismiss: {})
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        try store.addGrant(.init(sessionId: input.id, subjectFingerprint: "app:bundle=com.example.agent",
                                 subjectDisplayName: "Agent", duration: .always))
        controller.refresh()

        // 有授权的调用方：直接开，不问，而且不抢焦点
        controller.receive(.init(action: .open, id: input.id), caller: "Agent",
                           fingerprint: "app:bundle=com.example.agent") { _ in }
        XCTAssertEqual(prompts, 0)
        XCTAssertEqual(runtime.lastBringToFront, false)
        runtime.stop(id: input.id)

        // 换一个调用方：还是要问
        controller.receive(.init(action: .open, id: input.id), caller: "Other",
                           fingerprint: "app:bundle=com.other") { _ in }
        XCTAssertEqual(prompts, 1)
        decide?(false)
    }
}

@MainActor private final class FocusTrackingRuntime: BrowserSessionRuntime {
    private var open: Set<String> = []
    var lastBringToFront: Bool?
    var activeIDs: [String] { open.sorted() }
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool, completion: @escaping (Bool) -> Void) {
        lastBringToFront = bringToFront
        open.insert(snapshot.id)
        completion(true)
    }
    func stop(id: String) { open.remove(id) }
    func stopAll() { open.removeAll() }
}
