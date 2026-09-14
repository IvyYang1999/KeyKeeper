import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

/// 升级后的第一次启动，跑的是 App 真实的启动序列，吃的是 0.3.3 写出的文件（Fixtures/v0.3.3）。
///
/// 【曾经的 bug · 2026-09-13 深夜】首启把 service-grants.json 判成篡改、换成空文件——后台授权与
/// 访问记录全清空，模式被改成「先问我」。没有任何测试在发布前跑过「旧目录 + 新启动序列」。
@MainActor
final class UpgradeFirstLaunchTests: XCTestCase {
    private var dir: URL!
    private var keychain: FakeKeychain!
    private let codex = "app:team=unsigned:bundle=com.openai.codex:signing=com.openai.codex"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/v0.3.3")
        for name in ["meta.json", "grants.json", "service-grants.json"] {
            try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        keychain = FakeKeychain()
        // The credential values 0.3.3 left in the Keychain.
        keychain[SecItemBlobIO.defaultService] = Data(#"{"version":1,"credentials":{"openai":{"api-key":"synthetic-openai"},"vercel":{"token":"synthetic-vercel"}}}"#.utf8)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func stores() -> LaunchMaintenance.Stores {
        let meta = MetaStore(directory: dir, integrityIO: keychain.io(MetaIntegrityKey.service))
        let service = KeychainCredentialService(store: KeychainBlobStore(io: keychain.io(SecItemBlobIO.defaultService),
                                                                          loadMetadata: { try meta.load() }))
        return .init(meta: meta, inventory: service.inspectValueInventory, approvals: .inMemory(keychain),
                     directory: dir, sessionStore: nil)
    }

    func test升级首启什么都不丢() throws {
        let launch = stores()
        LaunchMaintenance.run(launch)

        // Credentials, values, plain fields, aliases: all still there and still verified.
        let meta = try launch.meta.loadVerified()
        XCTAssertNotEqual(meta.verdict, .tampered)
        XCTAssertEqual(meta.meta.credentials.count, 2)
        XCTAssertEqual(meta.meta.credentials["openai"]?.fields["org"]?.value, "org-synthetic")
        XCTAssertEqual(meta.meta.credentials["openai"]?.aliases, ["openai-old"])
        XCTAssertEqual(try launch.inventory(), ["openai": ["api-key"], "vercel": ["token"]])

        // The background approval and its audit trail moved over; the mode is untouched.
        XCTAssertEqual(try launch.approvals.mode(), .permissive)
        XCTAssertNotNil(try launch.approvals.valid(credentialId: "vercel", field: "token", fingerprint: codex, terminalSession: nil))
        XCTAssertEqual(try launch.approvals.auditEvents().count, 1)
        // Unowned and spent terminal approvals stay behind in the renamed file; nothing else is imported.
        XCTAssertEqual(try launch.approvals.all().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("grants.json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("service-grants.json.migrated-") })
    }

    func test第二次启动照样完整() throws {
        LaunchMaintenance.run(stores())
        let second = stores()
        LaunchMaintenance.run(second)
        XCTAssertEqual(try second.approvals.mode(), .permissive)
        XCTAssertNotNil(try second.approvals.valid(credentialId: "vercel", field: "token", fingerprint: codex, terminalSession: nil))
        XCTAssertNotEqual(try second.meta.loadVerified().verdict, .tampered)
    }

    /// 钥匙串暂时打不开（锁着、被拒）时，启动不能动文件，更不能清空；下次启动再搬。
    func test钥匙串打不开时启动不动文件() throws {
        keychain.failNextReads(of: "com.keykeeper.test.credentials.approvals", count: 2)   // 首启的两次读：迁移前的探测、清理
        LaunchMaintenance.run(stores())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("service-grants.json").path), "旧文件原样留着")
        LaunchMaintenance.run(stores())
        XCTAssertNotNil(try stores().approvals.valid(credentialId: "vercel", field: "token", fingerprint: codex, terminalSession: nil))
    }

    /// 启动序列和 AppDelegate 里跑的必须是同一段代码。
    func testAppDelegate走的是这段序列() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AppDelegate.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("LaunchMaintenance.run("))
        XCTAssertFalse(app.contains("pruneExpired()"), "清理不能绕开 LaunchMaintenance 单独跑")
    }
}
