import XCTest
@testable import KeyKeeperCore

/// 改名要做到：值不丢、旧名继续能用、授权跟着走；任何一步失败都不能留下缺值的库。
final class MetadataEditorTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var io: FakeBlobIO!
    private var blobStore: KeychainBlobStore!
    private var service: KeychainCredentialService!
    private var grants: GrantStore!
    private var serviceGrants: ServiceGrantStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kk-meta-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        io = FakeBlobIO()
        let store = metaStore!
        blobStore = KeychainBlobStore(io: io, loadMetadata: { try store.load() })
        service = KeychainCredentialService(store: blobStore)
        grants = GrantStore(directory: directory)
        serviceGrants = ServiceGrantStore(directory: directory)
        // The store must exist before metadata names a secret, as in the real Add flow.
        try service.createCredential(credentialId: "百度千帆", values: ["cc": "synthetic-value"], security: .standard)
        try metaStore.save(MetaFile(credentials: [
            "百度千帆": Credential(label: "百度千帆", notes: "", links: [],
                               fields: ["cc": CredentialField(secret: true), "region": CredentialField(value: "bj", secret: false)],
                               security: .standard, created: "2026-03-02", updated: "2026-03-02"),
        ]))
        try grants.addGrant(Grant(credentialId: "百度千帆", duration: .always))
        try serviceGrants.addGrant(ServiceGrant(credentialId: "百度千帆", subjectFingerprint: "fp", subjectDisplayName: "python3",
                                                fields: ["cc"], duration: .always))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func editor() -> MetadataEditor {
        MetadataEditor(session: service, metaStore: metaStore, grantStore: grants, serviceGrantStore: serviceGrants)
    }

    func test改组ID和字段名后值还在授权跟着走旧值键被清掉() throws {
        let result = try editor().apply(MetadataEdit(newGroupId: "baidu-qianfan", fieldRenames: ["cc": "api-key"]),
                                        groupId: "百度千帆")
        XCTAssertEqual(result.groupId, "baidu-qianfan")
        XCTAssertEqual(try service.retrieve(credentialId: "baidu-qianfan", fieldName: "api-key"), "synthetic-value")
        XCTAssertThrowsError(try service.retrieve(credentialId: "百度千帆", fieldName: "cc"))
        XCTAssertEqual(try blobStore.fieldNamesByCredential(), ["baidu-qianfan": ["api-key"]])
        XCTAssertNoThrow(try service.validateStorage())
        XCTAssertNotNil(try grants.findValidGrant(credentialId: "baidu-qianfan", sessionId: nil))
        XCTAssertTrue(try grants.grants(for: "百度千帆").isEmpty)
        let moved = try serviceGrants.grants(credentialId: "baidu-qianfan")
        XCTAssertEqual(moved.map(\.fields), [["api-key"]])
        XCTAssertEqual(try metaStore.load().credentials["baidu-qianfan"]?.fields["region"]?.value, "bj", "非密字段原样搬过去")
    }

    func test只改标题备注不碰钥匙串() throws {
        let writes = io.writeCount
        _ = try editor().apply(MetadataEdit(title: "百度千帆 · 学术", fieldDisplayNames: ["cc": "API Key"]), groupId: "百度千帆")
        XCTAssertEqual(io.writeCount, writes)
        XCTAssertEqual(try metaStore.load().credentials["百度千帆"]?.fields["cc"]?.displayName, "API Key")
    }

    func test写元数据失败时旧名下的值仍在库完整() throws {
        // A store that refuses to save stands in for a crash between the value copy and the metadata write.
        let metaURL = directory.appendingPathComponent("meta.json")
        let saved = try Data(contentsOf: metaURL)
        let failing = MetadataEditor(session: service, metaStore: FailingSaveMetaStore(base: metaStore), grantStore: grants,
                                     serviceGrantStore: serviceGrants)
        XCTAssertThrowsError(try failing.apply(MetadataEdit(newGroupId: "baidu-qianfan"), groupId: "百度千帆"))
        XCTAssertEqual(try Data(contentsOf: metaURL), saved)
        XCTAssertEqual(try service.retrieve(credentialId: "百度千帆", fieldName: "cc"), "synthetic-value")
        XCTAssertNoThrow(try service.validateStorage())
        XCTAssertNotNil(try grants.findValidGrant(credentialId: "百度千帆", sessionId: nil), "元数据没写成，授权也不动")
    }

    func test复制值时目标已有不同的值就拒绝() throws {
        try blobStore.save(credentialId: "baidu-qianfan", fieldName: "cc", value: "someone-else")
        XCTAssertThrowsError(try blobStore.copyValues(fromCredentialId: "百度千帆", toCredentialId: "baidu-qianfan", fieldMap: [:]))
        XCTAssertEqual(try service.retrieve(credentialId: "baidu-qianfan", fieldName: "cc"), "someone-else")
    }
}

/// Wraps a real store but refuses to save, to simulate a crash between steps.
private final class FailingSaveMetaStore: MetaStoring {
    let base: MetaStore
    init(base: MetaStore) { self.base = base }
    func load() throws -> MetaFile { try base.load() }
    func save(_ meta: MetaFile) throws { throw CocoaError(.fileWriteNoPermission) }
}
