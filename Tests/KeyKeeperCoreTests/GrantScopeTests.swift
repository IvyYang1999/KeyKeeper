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

    /// 已经存在的授权（yyt 库里 57 条 always）没有指纹。直接作废会让他所有 Agent 重新开始
    /// 弹窗——正是他点 always 想避免的事。所以沿用它，但**第一次被用到时钉死在那个调用方
    /// 身上**，之后别人再来就不算数。这比现状严格，永远不会比现状更松。
    func test旧授权首次使用时钉死在使用者身上() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = Grant(credentialId: "openai", duration: .always)
        try store.addGrant(legacy)
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                              fingerprint: "app:bundle=com.anything")?.subjectFingerprint,
                     "还没钉死之前谁都能用，和升级前一样")

        try store.pinGrantIfUnscoped(id: legacy.id, to: "app:bundle=com.example.agent", displayName: "Agent")

        XCTAssertNotNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                                 fingerprint: "app:bundle=com.example.agent"))
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", sessionId: nil,
                                              fingerprint: "app:bundle=com.other"),
                     "钉死之后别人再也蹭不到")
    }

    /// 钉死只发生一次，不会被后来的调用方改写。
    func test钉死之后不会被改写() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacy = Grant(credentialId: "openai", duration: .always)
        try store.addGrant(legacy)
        try store.pinGrantIfUnscoped(id: legacy.id, to: "first", displayName: "First")
        try store.pinGrantIfUnscoped(id: legacy.id, to: "second", displayName: "Second")
        XCTAssertEqual(try store.grants(for: "openai").first?.subjectFingerprint, "first")
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
