import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 旧版本写在文件里的授权（grants.json / service-grants.json）和登录态文档里的授权，搬进钥匙串条目——只搬一次。
final class ApprovalMigrationTests: XCTestCase {
    private var dir: URL!
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("KeyKeeperAppTests/Fixtures/v0.3.3")
    private let now = Date(timeIntervalSince1970: 1_789_000_000)  // 2026-09-10

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("approval-migration-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["grants.json", "service-grants.json"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test导入有主人的_跳过无主的_保留模式和审计_文件改名留档() throws {
        let store = ApprovalStore.inMemory()
        let result = try XCTUnwrap(try ApprovalMigration.runIfNeeded(directory: dir, store: store, now: now))
        XCTAssertEqual(result.imported, 1, "只有 codex 那条有主人且有效")
        XCTAssertEqual(result.skippedUnowned, 3, "三条无主的 strict 授权（始终、会话、已用掉的一次）都不导入")
        XCTAssertEqual(try store.mode(), .permissive, "升级用户保留 0.3.3 里的模式")
        XCTAssertEqual(try store.auditEvents().count, 1)
        let codex = "app:team=unsigned:bundle=com.openai.codex:signing=com.openai.codex"
        XCTAssertNotNil(try store.valid(credentialId: "vercel", field: "token", fingerprint: codex, terminalSession: nil, now: now))
        XCTAssertEqual(try store.all().first?.lastUsedAt, ISO8601DateFormatter().date(from: "2026-09-12T09:00:00Z"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("grants.json").path))
        XCTAssertEqual(result.renamedFiles.count, 2)
        XCTAssertTrue(result.renamedFiles.allSatisfy { $0.contains(".migrated-2026-09-10") }, result.renamedFiles.description)
        XCTAssertNil(try ApprovalMigration.runIfNeeded(directory: dir, store: store, now: now), "第二次什么都不做")
    }

    func test登录态文档里的授权也搬过来() throws {
        let sessions = Data(#"[{"id":"sg1","sessionId":"sess-1","subjectFingerprint":"unsigned:path=agent","subjectDisplayName":"Agent","duration":{"type":"always"},"createdAt":"2026-09-01T00:00:00Z","consumed":false}]"#.utf8)
        let store = ApprovalStore.inMemory()
        var handed = 0
        _ = try ApprovalMigration.runIfNeeded(directory: dir, store: store, sessionGrants: { handed += 1; return sessions }, now: now)
        XCTAssertEqual(handed, 1)
        XCTAssertNotNil(try store.valid(sessionId: "sess-1", fingerprint: "unsigned:path=agent", now: now))
    }

    func test没有旧文件也没有旧授权就不动() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("approval-migration-empty-\(UUID())")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let store = ApprovalStore.inMemory()
        XCTAssertNil(try ApprovalMigration.runIfNeeded(directory: empty, store: store, now: now))
        XCTAssertFalse(try store.exists())
    }
}

extension ApprovalMigrationTests {
    /// 旧文件没写模式 = 那个版本还没有这个概念，人从没选过：按新装机对待，enforced。
    func test旧文件没有模式_按enforced() throws {
        try Data(#"{"grants":[]}"#.utf8).write(to: dir.appendingPathComponent("service-grants.json"))
        let store = ApprovalStore.inMemory()
        _ = try ApprovalMigration.runIfNeeded(directory: dir, store: store, now: now)
        XCTAssertEqual(try store.mode(), .enforced)
    }
}
