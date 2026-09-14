import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-14：「我喜欢点『始终允许』的原因就是不想过了 1 小时再给同一个 Agent 因为同一件事授权。
/// 谁知道这个语义和现实差别这么大。」所以多一档：这次运行期间——进程活着就行，退出就失效。
final class ProcessApprovalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let subject = ApprovalSubject(fingerprint: "app:unsigned:path=abc", displayName: "codex")

    func test自己的进程活着_不存在的pid死了_同pid不同启动时间也算死() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = ProcessLiveness.startTime(pid: me)
        XCTAssertNotNil(start)
        XCTAssertTrue(ProcessLiveness.isAlive(pid: me, startedAt: start!))
        XCTAssertFalse(ProcessLiveness.isAlive(pid: me, startedAt: start!.addingTimeInterval(-3600)), "pid 被复用时启动时间对不上")
        XCTAssertFalse(ProcessLiveness.isAlive(pid: 2_000_000, startedAt: now))
        XCTAssertNil(ProcessLiveness.startTime(pid: 2_000_000))
    }

    func test进程授权_活着匹配_退出失效并被清理_一周硬上限() throws {
        let store = ApprovalStore.inMemory()
        nonisolated(unsafe) var alive = true
        store.processAlive = { pid, started in pid == 4242 && started == Date(timeIntervalSince1970: 1_799_999_000) && alive }
        let approval = Approval(subject: subject, target: .credential(id: "vercel", fields: nil),
                                duration: .process(pid: 4242, startedAt: Date(timeIntervalSince1970: 1_799_999_000)), createdAt: now)
        try store.add(approval)
        XCTAssertNotNil(try store.valid(credentialId: "vercel", field: "token", fingerprint: subject.fingerprint, terminalSession: nil, now: now))
        XCTAssertNotNil(try store.valid(credentialId: "vercel", field: "token", fingerprint: subject.fingerprint, terminalSession: "some-terminal", now: now.addingTimeInterval(3600 * 5)), "五小时后还在跑，还有效——这正是 1 小时那档做不到的")
        alive = false
        XCTAssertNil(try store.valid(credentialId: "vercel", field: "token", fingerprint: subject.fingerprint, terminalSession: nil, now: now))
        try store.pruneExpired(now: now)
        XCTAssertTrue(try store.all().isEmpty, "进程退出后清掉")
        alive = true
        try store.add(approval)
        XCTAssertNil(try store.valid(credentialId: "vercel", field: "token", fingerprint: subject.fingerprint, terminalSession: nil, now: now.addingTimeInterval(8 * 24 * 3600)), "一周硬上限")
    }

    func test进程授权_编码往返_同进程替换_不同进程并存() throws {
        let store = ApprovalStore.inMemory()
        store.processAlive = { _, _ in true }
        let a = Approval(subject: subject, target: .credential(id: "c", fields: nil), duration: .process(pid: 1, startedAt: now), createdAt: now)
        let b = Approval(subject: subject, target: .credential(id: "c", fields: nil), duration: .process(pid: 2, startedAt: now), createdAt: now)
        let a2 = Approval(subject: subject, target: .credential(id: "c", fields: nil), duration: .process(pid: 1, startedAt: now), createdAt: now.addingTimeInterval(1))
        try store.add(a); try store.add(b); try store.add(a2)
        XCTAssertEqual(try store.all().count, 2, "同一个进程的第二次替换第一次，另一个进程的并存")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(Approval.self, from: encoder.encode(a))
        XCTAssertEqual(round.duration, .process(pid: 1, startedAt: now))
    }

    func test身份里记下主体进程的pid() {
        let chain = [CallerProcess(pid: 100, parentPID: 80, executablePath: "/usr/local/bin/keykeeper"),
                     CallerProcess(pid: 80, parentPID: 70, executablePath: "/bin/zsh"),
                     CallerProcess(pid: 70, parentPID: 1, executablePath: "/Applications/Codex.app/Contents/MacOS/Codex", bundleIdentifier: "com.openai.codex")]
        XCTAssertEqual(CallerIdentityResolver.subjectProcess(from: chain)?.pid, 70, "绑到 App，不是它里面的 shell")
        let script = [CallerProcess(pid: 100, parentPID: 90, executablePath: "/usr/local/bin/keykeeper"),
                      CallerProcess(pid: 90, parentPID: 1, executablePath: "/bin/zsh", scriptPath: "/Users/x/job.sh")]
        XCTAssertEqual(CallerIdentityResolver.subjectProcess(from: script)?.pid, 90)
        XCTAssertNil(CallerIdentityResolver.subjectProcess(from: [CallerProcess(pid: 100, parentPID: 1, executablePath: "/usr/local/bin/keykeeper")]))
    }

    func test时长愿望折成三档() {
        XCTAssertEqual(RequestedDuration.session.folded, .thisRun)
        XCTAssertEqual(RequestedDuration.oneHour.folded, .thisRun)
        XCTAssertEqual(RequestedDuration(rawValue: "run"), .thisRun)
        XCTAssertEqual(RequestedDuration.always.folded, .always)
    }
}
