import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp
import KeyKeeperTestSupport

@MainActor final class BrowserSessionControllerTests: XCTestCase {
    func testDenyDisconnectAndExpiryNeverSaveAndApprovalIsSingleUse() throws {
        let io = FakeKeychainIO(), runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var now = Date(); var connected = true; var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { now },
            present: { _, reply in decide = reply }, dismiss: {}, approvals: .inMemory())
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
        let controller = BrowserSessionController(store: .init(io: FakeKeychainIO(), marker: SessionControllerMarker()),
            runtime: TestSessionRuntime(), present: { _, _ in }, dismiss: {}, approvals: .inMemory())
        controller.otherApprovalPending = { true }
        var result: BrowserSessionResponse?
        controller.receive(.init(action: .open, id: UUID().uuidString), caller: "Fixture") { result = $0 }
        XCTAssertEqual(result?.errorCode, .busy)
        XCTAssertEqual(controller.errorCode, .busy)
        XCTAssertFalse(controller.isPending)
    }

    func testStopCancelsPendingOpenAndLateApprovalCannotReopen() throws {
        let runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: FakeKeychainIO(), marker: SessionControllerMarker())
        let snapshot = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        try store.save(snapshot)
        var approve: ((Bool) -> Void)?; var result: BrowserSessionResponse?
        let controller = BrowserSessionController(store: store, runtime: runtime,
            present: { _, reply in approve = reply }, dismiss: {}, approvals: .inMemory())
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
        let io = FakeKeychainIO(), runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var prompts = 0; var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in prompts += 1; decide = reply }, dismiss: {}, approvals: .inMemory())
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
        let io = FakeKeychainIO(), runtime = FocusTrackingRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in decide = reply }, dismiss: {}, approvals: .inMemory())
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
        let io = FakeKeychainIO(), runtime = FocusTrackingRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var prompts = 0; var decide: ((Bool) -> Void)?
        let approvals = ApprovalStore.inMemory()
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in prompts += 1; decide = reply }, dismiss: {}, approvals: approvals)
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        try approvals.add(Approval(subject: .init(fingerprint: "app:bundle=com.example.agent", displayName: "Agent"),
                                   target: .session(id: input.id), duration: .always))
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

extension BrowserSessionControllerTests {
    /// 【安全审计】`stop` 没有鉴权，而它会顺手把一条**待批的**开窗请求取消掉——于是任何
    /// 本地进程都能打断你正在批准的那一次。停窗口本身无害，取消别人的待批不是。
    func test别的调用方的stop不能取消你正在批的请求() throws {
        let io = FakeKeychainIO(), runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: io, marker: SessionControllerMarker())
        var results: [BrowserSessionResponse] = []
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, _ in }, dismiss: {}, approvals: .inMemory())
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "S", cookies: [
            .init(name: "f", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        controller.refresh()

        controller.receive(.init(action: .open, id: input.id), caller: "Agent",
                           fingerprint: "app:bundle=com.example.agent") { results.append($0) }
        XCTAssertTrue(controller.isPending)

        // 另一个调用方来 stop：窗口可以停，但不能替你把待批的那次否掉
        controller.receive(.init(action: .stop, id: input.id), caller: "Other",
                           fingerprint: "app:bundle=com.other") { _ in }
        XCTAssertTrue(controller.isPending, "别人的 stop 不该取消你正在批的请求")
        XCTAssertTrue(results.isEmpty)

        // 自己来 stop 就可以
        controller.receive(.init(action: .stop, id: input.id), caller: "Agent",
                           fingerprint: "app:bundle=com.example.agent") { _ in }
        XCTAssertEqual(results.first?.errorCode, .denied)
    }
}

extension BrowserSessionControllerTests {
    private func savedSession(_ store: BrowserSessionStore) throws -> BrowserSessionImport {
        let input = BrowserSessionImport(id: UUID().uuidString, origin: "https://example.com", label: "S", cookies: [
            .init(name: "f", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
        _ = try store.save(input)
        return input
    }

    /// yyt：「存 Cookie 这件事，就是把自己账号的登录权交给了 Agent。理应做到和 KeyKeeper 的其它体验一致。」
    /// 于是登录态也能允许一次、一小时或始终——只记给这个调用方、这一个登录态。
    func test开登录态可以按时长记住这个调用方() throws {
        let runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: FakeKeychainIO(), marker: SessionControllerMarker())
        var durationReply: ((ApprovalDuration?) -> Void)?
        var offered: Bool?
        var plainPrompts = 0
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, _ in plainPrompts += 1 }, dismiss: {},
            presentWithDuration: { info, reply in offered = info.offersDurations; durationReply = reply }, approvals: .inMemory())
        let input = try savedSession(store)
        controller.refresh()
        let agent = "unsigned:path=agent"
        var results: [BrowserSessionResponse] = []

        controller.receive(.init(action: .open, id: input.id), caller: "Agent", fingerprint: agent) { results.append($0) }
        XCTAssertEqual(offered, true)
        durationReply?(.always)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(controller.approvals(for: input.id).map(\.subject.fingerprint), [agent])

        runtime.stop(id: input.id)
        durationReply = nil
        controller.receive(.init(action: .open, id: input.id), caller: "Agent", fingerprint: agent) { results.append($0) }
        XCTAssertNil(durationReply, "记住了就不再问")
        XCTAssertEqual(results.last?.success, true)

        runtime.stop(id: input.id)
        controller.receive(.init(action: .open, id: input.id), caller: "Other", fingerprint: "unsigned:path=other") { results.append($0) }
        XCTAssertNotNil(durationReply, "别的调用方照样要问")
        XCTAssertEqual(plainPrompts, 0)

        let approval = try XCTUnwrap(controller.approvals(for: input.id).first)
        controller.revokeApproval(id: approval.id)
        XCTAssertTrue(controller.approvals(for: input.id).isEmpty, "撤销之后就没了")
    }

    func test选仅这一次不留下授权() throws {
        let runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: FakeKeychainIO(), marker: SessionControllerMarker())
        var durationReply: ((ApprovalDuration?) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, _ in }, dismiss: {}, presentWithDuration: { _, reply in durationReply = reply }, approvals: .inMemory())
        let input = try savedSession(store)
        controller.refresh()
        var result: BrowserSessionResponse?
        controller.receive(.init(action: .open, id: input.id), caller: "Agent", fingerprint: "unsigned:path=agent") { result = $0 }
        durationReply?(.once)
        XCTAssertEqual(result?.success, true)
        XCTAssertTrue(controller.approvals(for: input.id).isEmpty)
    }

    func test认不出的调用方开登录态只能一次且不记() throws {
        let runtime = TestSessionRuntime()
        let store = BrowserSessionStore(io: FakeKeychainIO(), marker: SessionControllerMarker())
        var plainReply: ((Bool) -> Void)?
        var durationAsked = false
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { Date() },
            present: { _, reply in plainReply = reply }, dismiss: {},
            presentWithDuration: { _, _ in durationAsked = true }, approvals: .inMemory())
        let input = try savedSession(store)
        controller.refresh()
        var result: BrowserSessionResponse?
        controller.receive(.init(action: .open, id: input.id), caller: "?",
                           fingerprint: CallerSubject.unverifiedPrefix + "no-code-object") { result = $0 }
        XCTAssertFalse(durationAsked)
        plainReply?(true)
        XCTAssertEqual(result?.success, true)
        XCTAssertTrue(controller.approvals(for: input.id).isEmpty)
    }
}

@MainActor final class SessionDurationPromptTests: XCTestCase {
    func test菜单栏里不能替人选时长() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/TrustPrompt.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("opensWindow: asksDuration"))
    }

    func test新文案有中文() {
        for template in ["Allow for", "Just this once", "1 hour", "Always",
                         "Cookie values are never returned to the caller. Choosing longer than once lets this caller open this login again without asking, until the time is up or you revoke it on the Website sessions page."] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }
}

extension SessionDurationPromptTests {
    /// 给了「始终」却没处看、没处撤，等于没法收回。登录态页每条下面列出谁能不经询问打开，并能撤销。
    func test登录态页列出长期授权并能撤销() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/BrowserSessionViews.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("controller.approvals(for: item.id)"))
        XCTAssertTrue(source.contains("controller.revokeApproval(id: approval.id)"))
        let always = Approval(subject: .init(fingerprint: "unsigned:path=a", displayName: "codex\u{202E}\nx"),
                              target: .session(id: "s"), duration: .always)
        let line = SessionGrantCopy.line(always)
        XCTAssertTrue(line.contains("codex"), line)
        XCTAssertFalse(line.contains("\u{202E}"), line)
        for template in ["{0} can open it without asking", "{0} can open it without asking until {1}",
                         "{0} can open it once more without asking", "Revoke"] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }
}

@MainActor private final class LapseTrackingRuntime: BrowserSessionRuntime {
    var activeIDs: [String] = []
    var lapsed: [String] = []
    func validate(_ snapshot: BrowserSessionImport) throws {}
    func setReauthorizationHandler(_ handler: @escaping (String, @escaping (Bool) -> Void) -> Void) {}
    func open(_ snapshot: BrowserSessionImport, bringToFront: Bool, completion: @escaping (Bool) -> Void) { completion(true) }
    func stop(id: String) {}
    func stopAll() {}
    func reauthorizationLapsed(id: String) { lapsed.append(id) }
}

extension BrowserSessionControllerTests {
    /// 【独立审计第二轮】冻结窗口的重新授权确认框没有期限：不理它就一直挂着；来一个新请求会悄悄把它顶掉，
    /// 窗口卡在冻结态，按钮再也没反应。
    func test冻结窗口的重新授权会过期且不被别的请求顶掉() throws {
        let runtime = LapseTrackingRuntime()
        let store = BrowserSessionStore(io: FakeKeychainIO(), marker: SessionControllerMarker())
        var clock = Date()
        var presented = 0, dismissed = 0
        var decide: ((Bool) -> Void)?
        let controller = BrowserSessionController(store: store, runtime: runtime, now: { clock },
            present: { _, reply in presented += 1; decide = reply }, dismiss: { dismissed += 1 }, approvals: .inMemory())
        let input = try savedSession(store)
        controller.refresh()
        var outcome: Bool?
        controller.authorizeAgain(id: input.id) { outcome = $0 }
        XCTAssertEqual(presented, 1)

        var result: BrowserSessionResponse?
        controller.receive(.init(action: .open, id: input.id), caller: "Agent", fingerprint: "unsigned:path=a") { result = $0 }
        XCTAssertEqual(result?.errorCode, .busy, "别的请求等它答完，不顶掉它")
        XCTAssertEqual(presented, 1)

        clock = clock.addingTimeInterval(91)
        controller.expireReauthorizationIfNeeded()
        XCTAssertEqual(runtime.lapsed, [input.id], "过期后窗口保持冻结，按钮还能再问")
        XCTAssertGreaterThanOrEqual(dismissed, 1)
        decide?(true)
        XCTAssertNil(outcome, "过期之后再点也不算数")
    }
}
