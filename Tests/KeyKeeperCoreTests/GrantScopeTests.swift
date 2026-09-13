import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-13：「我点击 always 的原因是我不想再给我的 Agents 们授权了，而不是本机任意
/// 一个进程都可以。」
///
/// 这是 KeyKeeper 的错，不是用户的误解：`findValidGrant` 只按 credentialId 过滤，`.always`
/// 直接返回 true，连是谁在要都不看。而按钮上只写着「始终允许」。standard 凭据走的
/// ServiceGrant 本来就按调用方指纹匹配，偏偏 strict 这条线没有。
final class GrantScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func store() throws -> (GrantStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("grant-scope-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (GrantStore(directory: dir), dir)
    }

    func test新授权只认发起它的那个调用方() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.addGrant(.init(credentialId: "openai", duration: .always,
                                 subjectFingerprint: "app:bundle=com.example.agent",
                                 subjectDisplayName: "Agent"))

        XCTAssertNotNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                                 fingerprint: "app:bundle=com.example.agent"))
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                              fingerprint: "app:bundle=com.malware"),
                     "别的进程不该蹭到这条授权")
    }

    /// 【推翻我自己】原来的迁移是「旧授权照常放行，第一次被用到时钉死在使用者身上」。
    /// 安全审计把这条打穿了：库里 54 条未绑定的 always 里，有 `keykeeper-sparkle-signing`
    /// （发版签名私钥）和 `apple-notary`（Apple 应用专用密码）。在那套迁移下，本机**任何**
    /// 进程跑一句 `keykeeper run -c keykeeper-sparkle-signing -- …` 就能拿走签名私钥，
    /// 全程不弹窗——而且拿到之后那条授权还会被钉给攻击者，维护者下次发版反倒被拦。
    ///
    /// 「先给值、再认人」的顺序本身就是错的。现在未绑定的授权一律不匹配：第一次用到时
    /// 重新问一次，新授权带着调用方。代价是每条凭据多弹一次窗，一次而已。
    func test未绑定调用方的旧授权不再放行任何人() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.addGrant(.init(credentialId: "keykeeper-sparkle-signing", duration: .always))

        XCTAssertNil(try store.findValidGrant(credentialId: "keykeeper-sparkle-signing",
                                              sessionId: nil, fingerprint: "app:bundle=com.attacker"),
                     "未绑定的授权不能成为通配符")
        XCTAssertNil(try store.findValidGrant(credentialId: "keykeeper-sparkle-signing",
                                              sessionId: nil, fingerprint: nil))
        XCTAssertFalse(try store.hasLikelyValidGrant(credentialId: "keykeeper-sparkle-signing", sessionId: nil),
                       "命令行的自查也要认这条，否则它会跳过弹窗、然后被 App 拒绝")
    }

    func test旧版行为的回归测试_钉死机制已移除() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.addGrant(.init(credentialId: "openai", duration: .always))
        // 旧授权仍然留在文件里（界面上看得见、撤得掉），但对任何调用方都不再生效。
        XCTAssertEqual(try store.grants(for: "openai").count, 1)
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                              fingerprint: "app:bundle=com.example.agent"))
    }

    /// 不传指纹时（拿不到调用方身份）只认还没钉死的旧授权，绝不放行已经钉死的。
    func test拿不到调用方身份时不能蹭已钉死的授权() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.addGrant(.init(credentialId: "openai", duration: .always,
                                 subjectFingerprint: "app:bundle=com.example.agent",
                                 subjectDisplayName: "Agent"))
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: nil, fingerprint: nil))
    }

    /// 终端会话那一档的行为不变。
    func test本次会话那一档不受影响() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.addGrant(.init(credentialId: "openai", sessionId: "w0t1p0", duration: .session("w0t1p0"),
                                 subjectFingerprint: "f", subjectDisplayName: "Agent"))
        XCTAssertNotNil(try store.findValidGrant(credentialId: "openai", sessionId: "w0t1p0", fingerprint: "f"))
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: "other", fingerprint: "f"))
    }
}

/// 两个 store 都有 pruneExpired()，但全仓库零调用方——过期和用掉的授权永远留在明文文件里。
/// yyt 库里 103 条授权，其中 21 条是定时的，多半早就过期了。留着它们没有安全收益：
/// 那个文件是同 UID 进程能写的，行数越多越难看出有没有人往里加过东西。
final class GrantPruningTests: XCTestCase {
    func test清理会删掉过期和用掉的保留有效的() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)

        let expired = Grant(credentialId: "a", duration: .timed(Date().addingTimeInterval(-1)))
        let spent = Grant(credentialId: "b", duration: .once, consumed: true)
        let live = Grant(credentialId: "c", duration: .always, subjectFingerprint: "f", subjectDisplayName: "Agent")
        let unusedOnce = Grant(credentialId: "d", duration: .once)
        for grant in [expired, spent, live, unusedOnce] { try store.addGrant(grant) }

        try store.pruneExpired()

        XCTAssertEqual(try store.grants(for: "a").count, 0, "过期的该走")
        XCTAssertEqual(try store.grants(for: "b").count, 0, "用掉的该走")
        XCTAssertEqual(try store.grants(for: "c").count, 1, "有效的必须留下")
        XCTAssertEqual(try store.grants(for: "d").count, 1, "还没用过的 once 也必须留下")
    }

    /// 终端会话的授权有 24 小时硬上限，清理时不该因为「当前没有会话 ID」就把它们全删了。
    func test清理不会误删还在有效期内的会话授权() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prune-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)
        try store.addGrant(.init(credentialId: "a", sessionId: "w0t1p0", duration: .session("w0t1p0")))
        try store.addGrant(.init(credentialId: "b", sessionId: "old", duration: .session("old"),
                                 createdAt: Date().addingTimeInterval(-25 * 3600)))
        try store.pruneExpired()
        XCTAssertEqual(try store.grants(for: "a").count, 1, "今天的会话授权还有效")
        XCTAssertEqual(try store.grants(for: "b").count, 0, "超过 24 小时硬上限的该走")
    }
}

/// 【曾经的 bug】yyt 2026-09-13 晚：「现在为啥老弹出这个呀」——每次调用都弹授权窗，
/// 哪怕这条凭据对这个调用方已经有一条 always。
///
/// 原因是我把授权判据收紧成「必须对上调用方」之后，只改了 App 那一侧。命令行在发请求
/// 之前会先自查一次有没有授权，而它**算不出自己的指纹**（指纹是 App 从连接对端的 PID
/// 推出来的），于是传了 nil；按新规矩，nil 对不上任何已绑定的授权，自查永远失败，
/// 于是每次都去申请授权。
///
/// 命令行那次自查从来就不是安全边界（App 会重新判一遍），它只是为了少弹一次窗。所以它
/// 该问的是「这条凭据有没有一条还在有效期内的授权」，而不是「这条授权是不是发给我的」。
final class GrantPrecheckTests: XCTestCase {
    func test命令行自查不因为算不出指纹就认为没有授权() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("precheck-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)
        try store.addGrant(.init(credentialId: "dc", duration: .always,
                                 subjectFingerprint: "app:bundle=com.example.console",
                                 subjectDisplayName: "Console"))

        // 安全判定（App 侧）：拿不到指纹就不能放行
        XCTAssertNil(try store.findValidGrant(credentialId: "dc", sessionId: nil, fingerprint: nil))
        // 体验判定（命令行侧）：有一条还有效的授权，就别再弹窗了，交给 App 去判
        XCTAssertTrue(try store.hasLikelyValidGrant(credentialId: "dc", sessionId: nil))
        XCTAssertFalse(try store.hasLikelyValidGrant(credentialId: "other", sessionId: nil))
    }

    /// 过期的、用掉的仍然算「没有」，该弹还是要弹。
    func test自查不会把失效的授权当成有效() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("precheck-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)
        try store.addGrant(.init(credentialId: "dc", duration: .timed(Date().addingTimeInterval(-1)),
                                 subjectFingerprint: "f", subjectDisplayName: "X"))
        XCTAssertFalse(try store.hasLikelyValidGrant(credentialId: "dc", sessionId: nil))
    }
}
