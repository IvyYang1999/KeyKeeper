import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class StorageProtectionTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var io: FakeKeychainIO!
    private var session: KeychainCredentialService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        io = FakeKeychainIO()
        let metadata = metaStore!
        session = KeychainCredentialService(store: KeychainBlobStore(
            io: io, loadMetadata: { try metadata.load() }
        ))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func credential() -> Credential {
        Credential(label: "Synthetic fixture", notes: "", links: [],
                   fields: ["one": .init(secret: true), "two": .init(secret: true)],
                   security: .standard, created: "2026-01-01", updated: "2026-01-01")
    }

    // 整库缺失仍拒绝新增；部分缺失只允许全新 ID，编辑/删除继续保护旧数据。
    func testMissingStoreBlocksAllWritesAndPartialStoreOnlyAllowsCreate() throws {
        for partial in [false, true] {
            io.blob = partial ? Data(#"{"version":1,"credentials":{"fixture":{"one":"synthetic"}}}"#.utf8) : nil
            let original = MetaFile(credentials: ["fixture": credential()])
            try metaStore.save(original)
            let metadataBefore = try Data(contentsOf: metaStore.fileURL)
            let valuesBefore = io.blob

            let add = AddCredentialViewModel(session: session, store: metaStore)
            add.label = "New fixture"
            add.credentialId = "new"
            add.fields = [FieldEntry(name: "field", value: "synthetic")]
            let detail = CredentialDetailViewModel(credentialId: "fixture", credential: credential(), session: session, store: metaStore)
            detail.credential.notes = "metadata-only change"
            XCTAssertFalse(detail.saveChanges())
            XCTAssertTrue(detail.errorMessage?.contains("blocked") == true)

            let list = CredentialListViewModel(session: session, store: metaStore)
            XCTAssertFalse(list.delete(id: "fixture"))
            XCTAssertTrue(list.errorMessage?.contains("blocked") == true)
            XCTAssertEqual(try Data(contentsOf: metaStore.fileURL), metadataBefore)
            XCTAssertEqual(io.blob, valuesBefore)
            XCTAssertEqual(io.writes, 0)
            XCTAssertEqual(add.save(), partial)
            if partial {
                XCTAssertEqual(io.writes, 1)
                XCTAssertEqual(try session.retrieve(credentialId: "fixture", fieldName: "one"), "synthetic")
                XCTAssertNotNil(try metaStore.load().credentials["fixture"]?.fields["two"])
            } else {
                XCTAssertTrue(add.errorMessage?.contains("blocked") == true)
                XCTAssertEqual(try Data(contentsOf: metaStore.fileURL), metadataBefore)
                XCTAssertEqual(io.blob, valuesBefore)
            }
        }
    }

    func testFirstUseAndMultiFieldReplacementStillWork() throws {
        let add = AddCredentialViewModel(session: session, store: metaStore)
        add.label = "Synthetic fixture"
        add.credentialId = "fixture"
        add.fields = [FieldEntry(name: "one", value: "synthetic-one"), FieldEntry(name: "two", value: "synthetic-two")]
        XCTAssertTrue(add.save())
        let saved = try XCTUnwrap(metaStore.load().credentials["fixture"])
        let detail = CredentialDetailViewModel(credentialId: "fixture", credential: saved, session: session, store: metaStore)
        detail.fields = [FieldEntry(name: "replacement", value: "synthetic-replacement")]
        XCTAssertTrue(detail.saveChanges())
        XCTAssertEqual(try session.retrieve(credentialId: "fixture", fieldName: "replacement"), "synthetic-replacement")
        let list = CredentialListViewModel(session: session, store: metaStore)
        XCTAssertTrue(list.delete(id: "fixture"))
        XCTAssertTrue(try metaStore.load().credentials.isEmpty)
        XCTAssertTrue(add.save(), "A legitimately emptied store must support adding again")
    }
}


extension StorageProtectionTests {
    /// 【曾经的 bug · 2026-09-13 本机】列表里的删除用的是**整库**完整性检查：库里任意一条旧凭据
    /// 缺值，所有凭据都删不掉——包括一条刚存错、值完好的凭据。编辑早就改成按这一条凭据判断，
    /// 删除漏了。缺值的那条自己仍受保护（它的记录是找回的线索），别的凭据不该被它连累。
    func test别的凭据缺值不挡删除一条完好的凭据() throws {
        io.blob = Data(#"{"version":1,"credentials":{"fixture":{"one":"synthetic"},"healthy":{"one":"synthetic"}}}"#.utf8)
        var healthy = credential()
        healthy.fields = ["one": .init(secret: true)]
        try metaStore.save(MetaFile(credentials: ["fixture": credential(), "healthy": healthy]))

        let list = CredentialListViewModel(session: session, store: metaStore)
        XCTAssertTrue(list.delete(id: "healthy"), list.errorMessage ?? "")
        XCTAssertNil(try metaStore.load().credentials["healthy"])
        XCTAssertNotNil(try metaStore.load().credentials["fixture"], "缺值的那条原样保留")
        XCTAssertEqual(try session.storedFieldNames(credentialId: "fixture"), ["one"])

        XCTAssertFalse(list.delete(id: "fixture"), "缺值的那条自己仍受保护")
        XCTAssertNotNil(try metaStore.load().credentials["fixture"])
    }
}

extension StorageProtectionTests {
    /// 【独立审计 2026-09-13】保留变量名只在 metadata 改名路径上拦，App 里新建凭据绕过去了。
    func test界面新建不接受执行控制变量名() throws {
        let add = AddCredentialViewModel(session: session, store: metaStore)
        add.label = "Synthetic fixture"
        add.credentialId = "fixture"
        add.fields = [FieldEntry(name: "path", value: "synthetic")]
        XCTAssertFalse(add.save())
        XCTAssertNil(try metaStore.load().credentials["fixture"])
        XCTAssertEqual(io.writes, 0)
    }

    /// 同上：给已有凭据加一个字段，也绕过去了。
    func test详情页加字段不接受执行控制变量名() throws {
        try session.save(credentialId: "fixture", fieldName: "one", value: "synthetic-one", security: .standard)
        var existing = credential()
        existing.fields = ["one": .init(secret: true)]
        try metaStore.save(MetaFile(credentials: ["fixture": existing]))
        let detail = CredentialDetailViewModel(credentialId: "fixture", credential: existing, session: session, store: metaStore)
        detail.fields.append(FieldEntry(name: "node_options", value: "synthetic"))
        XCTAssertFalse(detail.saveChanges())
        XCTAssertNil(try metaStore.load().credentials["fixture"]?.fields["node_options"])
        XCTAssertEqual(try session.storedFieldNames(credentialId: "fixture"), ["one"])
    }
}
