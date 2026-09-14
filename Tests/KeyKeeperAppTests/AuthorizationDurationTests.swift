import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// yyt 2026-09-14：「一次 / 1 小时 / 始终都是时间维度。我点『始终』是因为不想过一小时再为同一件事授权。」
/// 三档改成事情维度：仅这一次 / 这次运行期间 / 以后都不问。
final class AuthorizationDurationTests: XCTestCase {
    typealias Choice = AuthorizationView.DurationChoice

    func test三档_认不出的只有一次_绑不到运行的没有中间档() {
        XCTAssertEqual(Choice.available(canRemember: true, canBindToRun: true), [.once, .thisRun, .always])
        XCTAssertEqual(Choice.available(canRemember: true, canBindToRun: false), [.once, .always])
        XCTAssertEqual(Choice.available(canRemember: false, canBindToRun: true), [.once])
    }

    func test推荐档_默认这次运行期间_从不推荐没提供的() {
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: true, review: nil), .thisRun)
        XCTAssertEqual(Choice.recommended(canRemember: true, canBindToRun: false, review: nil), .once, "绑不到运行就退到一次，不是「以后都不问」")
        XCTAssertEqual(Choice.recommended(canRemember: false, canBindToRun: true, review: nil), .once)
    }

    func test旧的时长愿望折进三档() {
        XCTAssertEqual(Choice(requested: .session), .thisRun)
        XCTAssertEqual(Choice(requested: .oneHour), .thisRun)
        XCTAssertEqual(Choice(requested: .thisRun), .thisRun)
        XCTAssertEqual(Choice(requested: .always), .always)
        XCTAssertEqual(Choice(requested: .once), .once)
    }

    /// 「这次运行期间」= 有终端会话就绑会话；没有就绑主体进程（pid + 启动时间）；两者都没有就不能发。
    func test这次运行期间落成什么授权() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let identity = CallerIdentity(peerPID: 5, subjectPID: 42,
                                      subject: CallerSubject(kind: .app, fingerprint: "app:unsigned:path=x", displayName: "codex", detail: ""))
        XCTAssertEqual(try DurationResolution.issued(.thisRun, sessionId: "w0t1p0:ABC", identity: identity, startTime: { _ in start }), .terminalSession("w0t1p0:ABC"))
        XCTAssertEqual(try DurationResolution.issued(.thisRun, sessionId: nil, identity: identity, startTime: { pid in pid == 42 ? start : nil }), .process(pid: 42, startedAt: start))
        XCTAssertEqual(try DurationResolution.issued(.thisRun, sessionId: "", identity: identity, startTime: { _ in start }), .process(pid: 42, startedAt: start))
        XCTAssertThrowsError(try DurationResolution.issued(.thisRun, sessionId: nil, identity: identity, startTime: { _ in nil }), "进程已经没了")
        XCTAssertThrowsError(try DurationResolution.issued(.thisRun, sessionId: nil, identity: nil))
        XCTAssertEqual(try DurationResolution.issued(.once, sessionId: nil, identity: nil), .once)
        XCTAssertEqual(try DurationResolution.issued(.always, sessionId: nil, identity: nil), .always)
    }

    func test授权提示从请求推导是否有终端会话() {
        let withSession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: "w0t1p0:ABC", sessionLabel: "Terminal (w0t1p0:A)", pid: 1
        ))
        let withoutSession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: nil, sessionLabel: "Unknown terminal", pid: 1
        ))
        let emptySession = AuthorizationPrompt.strict(AuthRequest(
            credentialId: "c", credentialLabel: "C", fieldNames: ["k"],
            sessionId: "", sessionLabel: nil, pid: 1
        ))
        XCTAssertTrue(withSession.hasTerminalSession)
        XCTAssertFalse(withoutSession.hasTerminalSession)
        XCTAssertFalse(emptySession.hasTerminalSession)
    }
}
