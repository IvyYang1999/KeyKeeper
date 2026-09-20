import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 一个授权模型、一个存储、一个策略。这里把三套旧模型各自的规矩合在一处钉住：
/// 只认发起它的调用方、认不出的身份存不进也匹配不上、一次性授权覆盖整次 run、终端会话 24 小时上限、
/// 登录态授权按登录态和调用方两者匹配、改名后授权跟着走。
final class ApprovalStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let agent = ApprovalSubject(fingerprint: "app:team=T:bundle=com.example.agent:signing=x", displayName: "Agent")

    private func credential(_ security: SecurityLevel) -> Credential {
        Credential(label: "C", notes: "", links: [], fields: ["key": .init(secret: true), "secret": .init(secret: true)],
                   security: security, created: "2026-01-01", updated: "2026-01-01")
    }
    private func caller(_ fingerprint: String = "app:team=T:bundle=com.example.agent:signing=x") -> CallerIdentity {
        CallerIdentity(peerPID: 1, subject: CallerSubject(kind: .app, fingerprint: fingerprint, displayName: "Agent", detail: ""))
    }

    // MARK: 谁

    func test新授权只认发起它的那个调用方() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .credential(id: "openai", fields: nil), duration: .always))
        XCTAssertNotNil(try store.valid(credentialId: "openai", field: "key", fingerprint: agent.fingerprint, terminalSession: nil))
        XCTAssertNil(try store.valid(credentialId: "openai", field: "key", fingerprint: "app:team=T:bundle=com.malware:signing=y", terminalSession: nil),
                     "别的进程不该蹭到这条授权")
    }

    /// yyt 库里曾有 54 条不记主人的「始终允许」——含发版签名私钥。不记主人的授权连存都存不进。
    func test认不出的身份存不进也匹配不上() throws {
        let store = ApprovalStore.inMemory()
        for fingerprint in ["", CallerSubject.unverifiedPrefix + "no-code-object"] {
            XCTAssertThrowsError(try store.add(Approval(subject: .init(fingerprint: fingerprint, displayName: "?"),
                                                        target: .credential(id: "openai", fields: nil), duration: .always))) {
                XCTAssertEqual($0 as? ApprovalIssuanceError, .unidentifiedCaller)
            }
            XCTAssertNil(try store.valid(credentialId: "openai", field: "key", fingerprint: fingerprint, terminalSession: nil))
        }
        XCTAssertTrue(try store.all().isEmpty)
    }

    // MARK: 多久

    func test终端会话授权只在那个会话里有效且24小时封顶() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .terminalSession("w0t1p0"), createdAt: now))
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: "w0t1p0", now: now))
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: "other", now: now))
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: nil, now: now))
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: "w0t1p0",
                                     now: now.addingTimeInterval(25 * 3600)), "24 小时硬上限")
    }

    func test两个终端各自的会话授权并存_同种时长互相替换() throws {
        let store = ApprovalStore.inMemory()
        let target = ApprovalTarget.credential(id: "c", fields: nil)
        try store.add(Approval(subject: agent, target: target, duration: .terminalSession("one"), createdAt: now))
        try store.add(Approval(subject: agent, target: target, duration: .terminalSession("two"), createdAt: now))
        XCTAssertEqual(try store.approvals(forCredential: "c").count, 2, "第二个终端的批准不能顶掉第一个")
        try store.add(Approval(subject: agent, target: target, duration: .always, createdAt: now))
        try store.add(Approval(subject: agent, target: target, duration: .always, createdAt: now))
        XCTAssertEqual(try store.approvals(forCredential: "c").filter { $0.duration == .always }.count, 1, "两条一样的「始终」只留一条")
    }

    /// 【独立审计第二轮】「仅这一次」在读完第一个字段后就被用掉；一条凭据有几个机密字段，run 就弹几次窗。
    func test一次批准覆盖这次run要读的所有字段() throws {
        let store = ApprovalStore.inMemory()
        let approval = Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .once, createdAt: now,
                                onceFieldsRemaining: ["key", "secret"])
        try store.add(approval)
        try store.noteUse(id: approval.id, field: "key", now: now)
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "secret", fingerprint: agent.fingerprint, terminalSession: nil, now: now), "第二个字段还没读")
        try store.noteUse(id: approval.id, field: "secret", now: now)
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: nil, now: now), "都读完就用掉了")
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: nil,
                                     now: now.addingTimeInterval(Approval.onceWindow + 1)), "没读完的字段过两分钟也失效")
    }

    func test没有字段记录的一次性批准读一次就用掉() throws {
        let store = ApprovalStore.inMemory()
        let approval = Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .once, createdAt: now)
        try store.add(approval)
        try store.noteUse(id: approval.id, field: "key", now: now)
        XCTAssertNil(try store.valid(credentialId: "c", field: "secret", fingerprint: agent.fingerprint, terminalSession: nil, now: now))
    }

    func test清理会删掉过期和用掉的_保留有效的() throws {
        let store = ApprovalStore.inMemory()
        let expired = Approval(subject: agent, target: .credential(id: "a", fields: nil), duration: .timed(now.addingTimeInterval(-1)))
        let spent = Approval(subject: agent, target: .credential(id: "b", fields: nil), duration: .once, consumed: true)
        let live = Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .always)
        let unusedOnce = Approval(subject: agent, target: .credential(id: "d", fields: nil), duration: .once, createdAt: now)
        let session = Approval(subject: agent, target: .credential(id: "e", fields: nil), duration: .terminalSession("w"), createdAt: now)
        let oldSession = Approval(subject: agent, target: .credential(id: "f", fields: nil), duration: .terminalSession("old"),
                                  createdAt: now.addingTimeInterval(-25 * 3600))
        for approval in [expired, spent, live, unusedOnce, session, oldSession] { try store.add(approval) }
        try store.pruneExpired(now: now)
        XCTAssertEqual(Set(try store.all().compactMap(\.target.credentialId)), ["c", "d", "e"])
    }

    // MARK: 什么

    func test按字段的授权只管列出的字段_不限字段的管全部() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .credential(id: "c", fields: ["key"]), duration: .always))
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "key", fingerprint: agent.fingerprint, terminalSession: nil))
        XCTAssertNil(try store.valid(credentialId: "c", field: "secret", fingerprint: agent.fingerprint, terminalSession: nil))
        try store.add(Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .always))
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "secret", fingerprint: agent.fingerprint, terminalSession: nil))
    }

    func test登录态授权按登录态和调用方两者匹配_三档失效方式() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .session(id: "a"), duration: .always, createdAt: now))
        XCTAssertNotNil(try store.valid(sessionId: "a", fingerprint: agent.fingerprint, now: now))
        XCTAssertNil(try store.valid(sessionId: "a", fingerprint: "app:team=T:bundle=com.other:signing=y", now: now), "换个调用方就不算数")
        XCTAssertNil(try store.valid(sessionId: "b", fingerprint: agent.fingerprint, now: now), "换条登录态也不算数")

        let once = Approval(subject: .init(fingerprint: "unsigned:path=f", displayName: "A"), target: .session(id: "s"), duration: .once, createdAt: now)
        try store.add(once)
        XCTAssertNotNil(try store.valid(sessionId: "s", fingerprint: "unsigned:path=f", now: now))
        try store.noteUse(id: once.id, field: nil, now: now)
        XCTAssertNil(try store.valid(sessionId: "s", fingerprint: "unsigned:path=f", now: now), "用过一次就没了")

        try store.add(Approval(subject: .init(fingerprint: "unsigned:path=g", displayName: "B"), target: .session(id: "s"),
                               duration: .timed(now.addingTimeInterval(3600)), createdAt: now))
        XCTAssertNotNil(try store.valid(sessionId: "s", fingerprint: "unsigned:path=g", now: now.addingTimeInterval(3599)))
        XCTAssertNil(try store.valid(sessionId: "s", fingerprint: "unsigned:path=g", now: now.addingTimeInterval(3600)))

        try store.revokeAll(forSession: "s")
        XCTAssertTrue(try store.approvals(forSession: "s").isEmpty, "删掉登录态，它的授权跟着走")
        XCTAssertEqual(try store.approvals(forSession: "a").count, 1)
    }

    func test改名后授权跟着走() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .credential(id: "百度千帆", fields: ["cc"]), duration: .always))
        try store.add(Approval(subject: agent, target: .credential(id: "百度千帆", fields: nil), duration: .once, onceFieldsRemaining: ["cc"]))
        try store.moveCredential(from: "百度千帆", to: "baidu-qianfan", fieldMap: ["cc": "api-key"])
        XCTAssertTrue(try store.approvals(forCredential: "百度千帆").isEmpty)
        let moved = try store.approvals(forCredential: "baidu-qianfan")
        XCTAssertEqual(moved.count, 2)
        XCTAssertTrue(moved.contains { $0.target == .credential(id: "baidu-qianfan", fields: ["api-key"]) })
        XCTAssertEqual(moved.first { $0.duration == .once }?.onceFieldsRemaining, ["api-key"])
    }

    func test新增字段前把整组授权冻结在旧字段() throws {
        let store = ApprovalStore.inMemory()
        try store.add(Approval(subject: agent, target: .credential(id: "oauth", fields: nil), duration: .always))
        try store.add(Approval(subject: .init(fingerprint: "unsigned:path=once", displayName: "once"),
                               target: .credential(id: "oauth", fields: nil), duration: .once,
                               onceFieldsRemaining: ["client-id"]))

        try store.freezeWildcardCredentialApprovals(credentialId: "oauth", existingFields: ["client-id"])

        let frozen = try store.approvals(forCredential: "oauth")
        XCTAssertEqual(Set(frozen.compactMap { approval -> String? in
            guard case .credential(_, let fields) = approval.target else { return nil }
            return fields?.joined(separator: ",")
        }), ["client-id"])
        XCTAssertNotNil(try store.valid(credentialId: "oauth", field: "client-id",
                                        fingerprint: agent.fingerprint, terminalSession: nil))
        XCTAssertNil(try store.valid(credentialId: "oauth", field: "client-secret",
                                     fingerprint: agent.fingerprint, terminalSession: nil))
    }

    func test撤销_容量_并发() throws {
        let store = ApprovalStore.inMemory()
        let a = Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .always)
        try store.add(a)
        XCTAssertFalse(try store.revoke(id: "no-such"), "撤销一个不存在的 ID 要如实说没有")
        XCTAssertTrue(try store.revoke(id: a.id))
        XCTAssertTrue(try store.all().isEmpty)

        let group = DispatchGroup()
        for i in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                try? store.add(Approval(subject: .init(fingerprint: "unsigned:path=\(i)", displayName: "\(i)"),
                                        target: .credential(id: "c", fields: nil), duration: .always))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(try store.all().count, 40, "并发写入一条都不能丢")

        for i in 40..<ApprovalStore.maxApprovals {
            try store.add(Approval(subject: .init(fingerprint: "unsigned:path=\(i)", displayName: "\(i)"), target: .credential(id: "c", fields: nil), duration: .always))
        }
        XCTAssertThrowsError(try store.add(Approval(subject: .init(fingerprint: "unsigned:path=more", displayName: "m"),
                                                    target: .credential(id: "c", fields: nil), duration: .always)))
    }

    /// 钥匙串打不开时读写都报错，绝不把空文档当成「没有授权」写回去。
    func test钥匙串打不开时不动() throws {
        let keychain = FakeKeychain()
        let store = ApprovalStore.inMemory(keychain)
        try store.add(Approval(subject: agent, target: .credential(id: "c", fields: nil), duration: .always))
        let before = keychain["com.keykeeper.test.credentials.approvals"]
        keychain.failNextReads(of: "com.keykeeper.test.credentials.approvals", count: 2)
        XCTAssertThrowsError(try store.all())
        XCTAssertThrowsError(try store.pruneExpired())
        XCTAssertEqual(keychain["com.keykeeper.test.credentials.approvals"], before)
    }

    // MARK: 策略

    func test宽松模式standard未命中也放行并记审计() throws {
        let store = ApprovalStore.inMemory()
        try store.setMode(.permissive)   // 2026-09-14 起新文档默认 enforced；这里测的是人主动关掉之后
        let decision = try AccessPolicy.decide(credential: credential(.standard), credentialId: "cron-api", field: "key",
                                               caller: caller(), terminalSession: nil, store: store, now: now)
        XCTAssertEqual(decision, .allowed(nil))
        XCTAssertEqual(try store.auditEvents().map(\.decision), ["allowed_without_grant"])
    }

    func test严格模式standard未命中要询问并记审计() throws {
        let store = ApprovalStore.inMemory()
        try store.setMode(.enforced)
        let decision = try AccessPolicy.decide(credential: credential(.standard), credentialId: "cron-api", field: "key",
                                               caller: caller(), terminalSession: nil, store: store, now: now)
        XCTAssertEqual(decision, .needsApproval)
        XCTAssertEqual(try store.auditEvents().map(\.decision), ["prompt_required"])
    }

    func teststrict凭据只认自己的授权_不记审计() throws {
        let store = ApprovalStore.inMemory()
        try store.setMode(.permissive)
        XCTAssertEqual(try AccessPolicy.decide(credential: credential(.strict), credentialId: "s", field: "key",
                                               caller: caller(), terminalSession: nil, store: store, now: now), .needsApproval)
        XCTAssertTrue(try store.auditEvents().isEmpty)
        let approval = Approval(subject: agent, target: .credential(id: "s", fields: nil), duration: .always, createdAt: now)
        try store.add(approval)
        XCTAssertEqual(try AccessPolicy.decide(credential: credential(.strict), credentialId: "s", field: "key",
                                               caller: caller(), terminalSession: nil, store: store, now: now), .allowed(approval))
    }

    func test命中的授权放行_读完才记用过() throws {
        let store = ApprovalStore.inMemory()
        let approval = Approval(subject: agent, target: .credential(id: "cron-api", fields: ["key", "secret"]), duration: .once,
                                createdAt: now, onceFieldsRemaining: ["key", "secret"])
        try store.add(approval)
        guard case .allowed(let matched?) = try AccessPolicy.decide(credential: credential(.standard), credentialId: "cron-api", field: "key",
                                                                     caller: caller(), terminalSession: nil, store: store, now: now)
        else { return XCTFail("expected matching approval") }
        XCTAssertEqual(matched.id, approval.id)
        XCTAssertEqual(try store.all().first?.lastUsedAt, nil, "判定不等于用掉；值发出去才记")
    }

    /// 【曾经的 bug】nil session 下选「本终端会话」必须拒绝，而不是写一条随机会话的授权。
    func test没有终端会话时不能选本会话() {
        XCTAssertThrowsError(try AccessPolicy.resolveIssuedDuration(requested: .terminalSession(""), terminalSession: nil)) {
            XCTAssertEqual($0 as? ApprovalIssuanceError, .missingTerminalSession)
        }
        XCTAssertEqual(try AccessPolicy.resolveIssuedDuration(requested: .terminalSession("placeholder"), terminalSession: "t"), .terminalSession("t"))
        XCTAssertEqual(try AccessPolicy.resolveIssuedDuration(requested: .always, terminalSession: nil), .always)
    }

    func test认不出的调用方要strict凭据时直接拒绝() {
        XCTAssertNotNil(AccessPolicy.strictRefusal(for: CallerSubject.unverifiedPrefix + "no-code-object"))
        XCTAssertNil(AccessPolicy.strictRefusal(for: "unsigned:path=abc"))
    }

    func test文档编码往返稳定_旧的session时长名也认() throws {
        let approval = Approval(subject: agent, target: .credential(id: "c", fields: ["a"]), duration: .terminalSession("w"), createdAt: now,
                                lastUsedAt: now, consumed: false, onceFieldsRemaining: ["a"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Approval.self, from: encoder.encode(approval)), approval)
        let legacy = Data(#"{"type":"session","value":"w0"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ApprovalDuration.self, from: legacy), .terminalSession("w0"))
    }
}

// MARK: - 2026-09-14 傍晚：审查员设置和默认模式

extension ApprovalStoreTests {
    /// 【今天自己埋的 critical】审查员设置放在 UserDefaults 里，本机任何进程都能把它指向一条真凭据和
    /// 攻击者的地址。搬进这个 App 独占的钥匙串条目——和授权记录同一处，别的进程写不了。
    func test审查员设置存在钥匙串文档里_旧文档没有也能读() throws {
        let store = ApprovalStore.inMemory()
        XCTAssertNil(try store.reviewerSettings())
        let settings = ReviewerSettings(enabled: true, apiKey: "sk-test", baseURL: "https://api.deepseek.com",
                                        api: .openAICompatible, model: "deepseek-chat")
        try store.setReviewerSettings(settings)
        XCTAssertEqual(try store.reviewerSettings(), settings)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let old = Data(#"{"version":2,"mode":"enforced","approvals":[],"auditEvents":[]}"#.utf8)
        XCTAssertNil(try decoder.decode(ApprovalDocument.self, from: old).reviewerSettings)
    }

    /// 新装机默认「后台读取要先问」。以前默认 permissive：新用户不去设置里打开开关，
    /// 任何本机进程都能无提示读「后台可用」的 key。升级用户保留自己原来的模式（迁移另有测试）。
    func test新文档默认enforced() throws {
        XCTAssertEqual(ApprovalDocument().mode, .enforced)
        XCTAssertEqual(try ApprovalStore.inMemory().mode(), .enforced)
    }
}

extension ApprovalStoreTests {
    /// 【独立审计 2026-09-14】「仅这一次」在 120 秒窗口里同一个字段能被读很多次：isValid 只看时间，不看
    /// 这个字段用没用过。现在每个字段只能取一次，窗口只是给同一次运行里的其他字段留的。
    func test一次性授权_每个字段只能取一次() throws {
        let store = ApprovalStore.inMemory()
        let approval = Approval(subject: .init(fingerprint: "unsigned:path=a", displayName: "a"),
                                target: .credential(id: "c", fields: nil), duration: .once, createdAt: now,
                                onceFieldsRemaining: ["key", "secret"])
        try store.add(approval)
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "key", fingerprint: "unsigned:path=a", terminalSession: nil, now: now))
        try store.noteUse(id: approval.id, field: "key")
        XCTAssertNil(try store.valid(credentialId: "c", field: "key", fingerprint: "unsigned:path=a", terminalSession: nil, now: now.addingTimeInterval(1)), "同一字段第二次不行")
        XCTAssertNotNil(try store.valid(credentialId: "c", field: "secret", fingerprint: "unsigned:path=a", terminalSession: nil, now: now.addingTimeInterval(1)), "同一次运行的另一个字段还行")
        XCTAssertNil(try store.valid(credentialId: "c", field: "other", fingerprint: "unsigned:path=a", terminalSession: nil, now: now), "没列在里面的字段一开始就不行")
    }

    /// 【独立审计 2026-09-14】授权列表回给任何进程时带完整指纹（脚本路径哈希、bundle）。回传前只留档位。
    func test授权列表回传前抹掉指纹() {
        let approval = Approval(subject: .init(fingerprint: "script:sha256=abcdef", displayName: "daily.sh"),
                                target: .credential(id: "c", fields: nil), duration: .always)
        XCTAssertEqual(approval.redactedForCaller().subject.fingerprint, "script:…")
        XCTAssertEqual(approval.redactedForCaller().subject.displayName, "daily.sh")
        let signed = Approval(subject: .init(fingerprint: "app:team=T:bundle=b:signing=s", displayName: "b"),
                              target: .credential(id: "c", fields: nil), duration: .always)
        XCTAssertEqual(signed.redactedForCaller().subject.fingerprint, "app:…")
    }
}
