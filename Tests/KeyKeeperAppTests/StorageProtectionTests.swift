import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class StorageProtectionTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var io: StorageProtectionIO!
    private var session: KeychainCredentialService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        io = StorageProtectionIO()
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

private final class StorageProtectionIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var writes = 0
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        writes += 1
        blob = data
    }
}
