import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 改名要做到：值不丢、旧名继续能用、授权跟着走；任何一步失败都不能留下缺值的库。
final class MetadataEditorTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var io: FakeKeychainIO!
    private var blobStore: KeychainBlobStore!
    private var service: KeychainCredentialService!
    private var grants: GrantStore!
    private var serviceGrants: ServiceGrantStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kk-meta-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        io = FakeKeychainIO()
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
        try grants.addGrant(Grant(credentialId: "百度千帆", duration: .always, subjectFingerprint: "fp", subjectDisplayName: "python3"))
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
        XCTAssertNotNil(try grants.findValidGrant(credentialId: "baidu-qianfan", sessionId: nil, fingerprint: "fp"))
        XCTAssertTrue(try grants.grants(for: "百度千帆").isEmpty)
        let moved = try serviceGrants.grants(credentialId: "baidu-qianfan")
        XCTAssertEqual(moved.map(\.fields), [["api-key"]])
        XCTAssertEqual(try metaStore.load().credentials["baidu-qianfan"]?.fields["region"]?.value, "bj", "非密字段原样搬过去")
    }

    /// 【曾经的 bug】yyt 的库里有 49 条凭据的值在 9 月那次钥匙串重建中丢了。改名前的完整性
    /// 检查是全库范围的，于是**任何一条**凭据都改不动，连值齐全的那几条也不行。
    /// 检查应该只看正在编辑的这一条。
    func test曾经的Bug别的凭据缺值不该挡住这一条的改名() throws {
        var meta = try metaStore.load()
        meta.credentials["broken"] = Credential(label: "Broken", notes: "", links: [],
                                                fields: ["lost": CredentialField(secret: true)],
                                                security: .standard, created: "2026-09-01", updated: "2026-09-01")
        try metaStore.save(meta)   // 钥匙串里从来没有 broken.lost 的值

        let result = try editor().apply(MetadataEdit(newGroupId: "baidu-qianfan"), groupId: "百度千帆")
        XCTAssertEqual(result.groupId, "baidu-qianfan")
        XCTAssertEqual(try service.retrieve(credentialId: "baidu-qianfan", fieldName: "cc"), "synthetic-value")
    }

    /// 反过来：正在编辑的这一条自己缺值时，仍然要拦住——否则改名会把缺口固化。
    func test这一条自己缺值时仍然拦住() throws {
        var meta = try metaStore.load()
        meta.credentials["百度千帆"]?.fields["missing"] = CredentialField(secret: true)
        try metaStore.save(meta)

        XCTAssertThrowsError(try editor().apply(MetadataEdit(newGroupId: "baidu-qianfan"), groupId: "百度千帆"))
        XCTAssertNotNil(try metaStore.load().credentials["百度千帆"], "没改成，原样留着")
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
        XCTAssertNotNil(try grants.findValidGrant(credentialId: "百度千帆", sessionId: nil, fingerprint: "fp"), "元数据没写成，授权也不动")
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
