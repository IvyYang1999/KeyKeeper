import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

private final class RecoveryKeyIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws { blob = data }
}

/// 【安全遗留 2026-09-13】meta.json 的签名验不过时，命令行不再信任它，App 里却什么都不显示、也没有
/// 恢复办法——用户只会看到 Agent 莫名其妙地拿不到值，而且没有任何办法让它恢复。
@MainActor
final class MetadataTamperRecoveryTests: XCTestCase {
    private var dir: URL!
    private var store: MetaStore!
    private var vm: CredentialListViewModel!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-recovery-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = MetaStore(directory: dir, integrityIO: RecoveryKeyIO())
        try store.save(MetaFile(credentials: ["svc": Credential(
            label: "Svc", notes: "", links: [], fields: ["region": .init(value: "us-east-1", secret: false)],
            security: .standard, created: "2026-01-01", updated: "2026-01-01")]))
        let metadata = store!
        let session = KeychainCredentialService(store: KeychainBlobStore(io: RecoveryKeyIO(), loadMetadata: { try metadata.load() }))
        vm = CredentialListViewModel(session: session, store: store)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func tamper() throws {
        var meta = try store.load()
        meta.credentials["svc"]?.fields["region"]?.value = "attacker-controlled"
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meta).write(to: store.fileURL)
    }

    func test没被改过时不提示() {
        vm.load()
        XCTAssertFalse(vm.metadataTampered)
    }

    func test被改过会提示且不确认身份就不签() throws {
        try tamper()
        vm.load()
        XCTAssertTrue(vm.metadataTampered)
        vm.confirmOwner = { _, reply in reply(false) }
        vm.trustCurrentMetadata()
        XCTAssertTrue(vm.metadataTampered)
        XCTAssertEqual(try store.loadVerified().verdict, .tampered)
    }

    func test确认身份后按看到的内容重新签名() throws {
        try tamper()
        vm.load()
        vm.confirmOwner = { _, reply in reply(true) }
        vm.trustCurrentMetadata()
        XCTAssertFalse(vm.metadataTampered)
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
        XCTAssertEqual(try store.load().credentials["svc"]?.fields["region"]?.value, "attacker-controlled",
                       "签的是用户看到的那一版，不偷偷改内容")
    }
}

extension MetadataTamperRecoveryTests {
    func test提示出现在凭据列表上方且有中文() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let window = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/MainWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("listVM.metadataTampered"))
        for template in ["Your credential list was changed outside KeyKeeper",
                         "Until you check it, KeyKeeper hands no keys to agents. Look through the list: titles, which fields are secret, plain values. If it is all as you left it, confirm and KeyKeeper will trust this version.",
                         "It's all as I left it", "confirm that the credential list is correct", "Could not confirm the list: {0}"] {
            XCTAssertNotEqual(AppL10n.render(template, language: "zh-Hans"), template, template)
        }
    }
}
