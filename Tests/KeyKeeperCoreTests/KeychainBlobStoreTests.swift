import Foundation
import XCTest
import Security
@testable import KeyKeeperCore

/// In-memory IO so these tests (and pre-commit) never touch the real keychain —
/// 经验.md 铁律：安全工具的测试绝不能碰真凭据源。
final class FakeBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var readError: Error?
    var writeError: Error?
    private(set) var writeCount = 0
    var beforeWrite: (() -> Void)?

    func readBlob() throws -> Data? {
        if let readError { throw readError }
        return blob
    }

    func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        if let writeError { throw writeError }
        beforeWrite?()
        if replacingExisting && blob == nil { throw CredentialStorageError.missingStore }
        if !replacingExisting && blob != nil { throw KeychainError.saveFailed(-25299) }
        writeCount += 1
        blob = data
    }
}

final class KeychainBlobStoreTests: XCTestCase {
    func testSystemUpdateNotFoundNeverFallsBackToAdd() {
        var adds = 0
        let io = SecItemBlobIO(service: "test-only", updateItem: { _, _ in errSecItemNotFound }, addItem: { _ in
            adds += 1
            return errSecSuccess
        })
        XCTAssertThrowsError(try io.writeBlob(Data(), replacingExisting: true)) { error in
            guard case CredentialStorageError.missingStore = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertEqual(adds, 0)
    }

    func testSystemCreateCollisionNeverFallsBackToUpdate() {
        var updates = 0
        let io = SecItemBlobIO(service: "test-only", updateItem: { _, _ in
            updates += 1
            return errSecSuccess
        }, addItem: { _ in errSecDuplicateItem })
        XCTAssertThrowsError(try io.writeBlob(Data(), replacingExisting: false))
        XCTAssertEqual(updates, 0)
    }

    private func metadata() -> MetaFile {
        MetaFile(credentials: ["fixture": Credential(
            label: "Synthetic", notes: "", links: [], fields: ["field": .init(secret: true)],
            security: .standard, created: "2026-01-01", updated: "2026-01-01"
        )])
    }

    // 【曾经的 bug】进程重启后也必须通过恢复的目录识别缺失存储。
    func testRestoredMetadataBlocksFreshStoreCreation() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io, loadMetadata: { self.metadata() })
        XCTAssertThrowsError(try store.save(credentialId: "new", fieldName: "field", value: "synthetic")) { error in
            guard case CredentialStorageError.missingStore = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 0)
        XCTAssertThrowsError(try store.validateStorage())
    }

    func testUnreadableMetadataCannotAuthorizeCreation() {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io, loadMetadata: { throw CocoaError(.fileReadNoPermission) })
        XCTAssertThrowsError(try store.save(credentialId: "new", fieldName: "field", value: "synthetic"))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 0)
    }

    func testReadWriteRaceCannotRecreateDisappearingItem() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)
        try store.save(credentialId: "fixture", fieldName: "field", value: "synthetic")
        io.beforeWrite = { io.blob = nil }
        XCTAssertThrowsError(try store.save(credentialId: "other", fieldName: "field", value: "synthetic"))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 1)
    }

    func testCompetingCreatorCannotBeOverwritten() throws {
        let io = FakeBlobIO()
        let other = Data(#"{"version":1,"credentials":{"other":{"field":"synthetic"}}}"#.utf8)
        let store = KeychainBlobStore(io: io)
        io.beforeWrite = { io.blob = other }
        XCTAssertThrowsError(try store.save(credentialId: "fixture", fieldName: "field", value: "synthetic"))
        XCTAssertEqual(io.blob, other)
        XCTAssertEqual(io.writeCount, 0)
    }

    func testRecoveredValuesPermitWritesAfterFailedAttempt() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io, loadMetadata: { self.metadata() })
        XCTAssertThrowsError(try store.validateStorage())
        // Synthetic restoration only. Production recovery requires an independently usable Keychain.
        io.blob = Data(#"{"version":1,"credentials":{"fixture":{"field":"synthetic"}}}"#.utf8)
        XCTAssertNoThrow(try store.validateStorage())
        XCTAssertNoThrow(try store.save(credentialId: "new", fieldName: "field", value: "synthetic"))
        XCTAssertEqual(try store.fieldNamesByCredential().count, 2)
    }

    func testMetadataWithoutSecretFieldsAllowsFirstUse() throws {
        var meta = metadata()
        meta.credentials["fixture"]?.fields = ["public": .init(value: "synthetic", secret: false)]
        let store = KeychainBlobStore(io: FakeBlobIO(), loadMetadata: { meta })
        XCTAssertNoThrow(try store.validateStorage())
        XCTAssertNoThrow(try store.save(credentialId: "new", fieldName: "field", value: "synthetic"))
    }

    // 【曾经的 bug】已读写的条目消失后，不能把下一次保存当成首次建库。
    func testMissingItemAfterSaveDoesNotRecreateStore() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)
        try store.save(credentialId: "fixture", fieldName: "field", value: "synthetic")
        io.blob = nil

        XCTAssertThrowsError(try store.save(credentialId: "other", fieldName: "field", value: "synthetic"))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 1)
    }

    func test保存后能取回且按字段隔离() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)

        try store.save(credentialId: "openai", fieldName: "api-key", value: "opaque-a")
        try store.save(credentialId: "openai", fieldName: "org-id", value: "opaque-b")
        try store.save(credentialId: "stripe", fieldName: "token", value: "opaque-c")

        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "api-key"), "opaque-a")
        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "org-id"), "opaque-b")
        XCTAssertEqual(try store.retrieve(credentialId: "stripe", fieldName: "token"), "opaque-c")
        XCTAssertEqual(
            try store.fieldNamesByCredential(),
            ["openai": ["api-key", "org-id"], "stripe": ["token"]]
        )
    }

    func test缺失字段抛notFound() {
        let store = KeychainBlobStore(io: FakeBlobIO())
        XCTAssertThrowsError(try store.retrieve(credentialId: "nope", fieldName: "x")) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func test覆盖保存替换旧值() throws {
        let store = KeychainBlobStore(io: FakeBlobIO())
        try store.save(credentialId: "c", fieldName: "f", value: "old")
        try store.save(credentialId: "c", fieldName: "f", value: "new")
        XCTAssertEqual(try store.retrieve(credentialId: "c", fieldName: "f"), "new")
    }

    func test删除字段且删空凭据清理条目() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)
        try store.save(credentialId: "c", fieldName: "f1", value: "v1")
        try store.save(credentialId: "c", fieldName: "f2", value: "v2")

        try store.delete(credentialId: "c", fieldName: "f1")
        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f1"))
        XCTAssertEqual(try store.retrieve(credentialId: "c", fieldName: "f2"), "v2")

        try store.delete(credentialId: "c", fieldName: "f2")
        XCTAssertEqual(try store.fieldNamesByCredential(), [:])

        XCTAssertThrowsError(try store.delete(credentialId: "c", fieldName: "f2")) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func test损坏的blob拒绝服务而不是当成空库() throws {
        let io = FakeBlobIO()
        io.blob = Data("{ not json".utf8)
        let store = KeychainBlobStore(io: io)

        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f"))
        XCTAssertThrowsError(try store.save(credentialId: "c", fieldName: "f", value: "v"))
        XCTAssertEqual(io.writeCount, 0, "corrupt store must never be overwritten")
    }

    func testIO错误原样上抛() {
        let io = FakeBlobIO()
        io.readError = KeychainError.retrieveFailed(-25293)
        let store = KeychainBlobStore(io: io)
        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f")) { error in
            guard case KeychainError.retrieveFailed = error else {
                return XCTFail("expected retrieveFailed, got \(error)")
            }
        }
    }

    func test并发读写不丢字段() throws {
        let store = KeychainBlobStore(io: FakeBlobIO())
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            try? store.save(credentialId: "cred\(index % 4)", fieldName: "field\(index)", value: "v\(index)")
        }
        let fields = try store.fieldNamesByCredential()
        XCTAssertEqual(fields.values.reduce(0) { $0 + $1.count }, 32)
    }
}

final class KeychainCredentialServiceTests: XCTestCase {
    func test永远是解锁态且CRUD直通() throws {
        let service = KeychainCredentialService(store: KeychainBlobStore(io: FakeBlobIO()))
        XCTAssertEqual(service.status(), .unlocked(expiresAt: nil))

        try service.save(credentialId: "c", fieldName: "f", value: "opaque", security: .strict)
        XCTAssertEqual(try service.retrieve(credentialId: "c", fieldName: "f"), "opaque")
        try service.delete(credentialId: "c", fieldName: "f")
        XCTAssertThrowsError(try service.retrieve(credentialId: "c", fieldName: "f"))
    }

    /// 【曾经的风险】「绝不自动重建空库」原本只看「meta 里还有没有机密字段」。非机密字段能
    /// 互转之后，一条库可能一个机密字段都不剩，防线随之关闭：此时钥匙串条目读不到（误删、
    /// 换机器只同步了 meta），就会静默新建一个空条目——正是 2026-09 丢掉 49 个值的那条路。
    /// 只要这份 meta 记着「这台机器上曾经建过库」，就得一直守着。
    func test曾经的风险全是明文字段时也不自动重建空库() throws {
        let meta = MetaFile(storeInitialized: true, credentials: [
            "notary": Credential(label: "Notary", notes: "", links: [],
                                 fields: ["apple-id": CredentialField(value: "a@b.invalid", secret: false)],
                                 security: .standard, created: "2026-09-13", updated: "2026-09-13"),
        ])
        let io = FakeBlobIO()          // 钥匙串里什么都读不到
        let store = KeychainBlobStore(io: io, loadMetadata: { meta })

        XCTAssertThrowsError(try store.save(credentialId: "notary", fieldName: "token", value: "v")) { error in
            guard case CredentialStorageError.missingStore = error else {
                return XCTFail("应该拒绝并提示恢复钥匙串，实际 \(error)")
            }
        }
        XCTAssertNil(io.blob, "绝不能新建一个空条目")
    }

    /// 全新的机器、从没建过库：正常建得起来。
    func test全新的库仍然可以建起来() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io, loadMetadata: { MetaFile() })
        XCTAssertNoThrow(try store.createCredential(credentialId: "new", values: ["token": "v"]))
        XCTAssertNotNil(io.blob)
    }

    func test曾经有过库这个标记只加不减() {
        // 库里有值 → 打上标记
        XCTAssertEqual(StoreInitializationMarker.updated(MetaFile(), hasStoredValues: true)?.storeInitialized, true)
        // 已经有标记 → 不用重写
        XCTAssertNil(StoreInitializationMarker.updated(MetaFile(storeInitialized: true), hasStoredValues: true))
        // 读不到值时绝不打标记，也绝不清掉已有的标记
        XCTAssertNil(StoreInitializationMarker.updated(MetaFile(), hasStoredValues: false))
        XCTAssertNil(StoreInitializationMarker.updated(MetaFile(storeInitialized: true), hasStoredValues: false))
    }

    /// 标记已经在了就不该再去读钥匙串——这段代码跑在 App 启动路径上，每次启动（包括
    /// 开机自启）都读一次，等于把「可能弹系统密码框」的动作放进了没有窗口的时刻。
    func test已经有标记时不再去读钥匙串() {
        var reads = 0
        let inventory: () throws -> [String: Set<String>] = { reads += 1; return ["a": ["token"]] }

        XCTAssertNil(StoreInitializationMarker.updated(MetaFile(storeInitialized: true), inventory: inventory))
        XCTAssertEqual(reads, 0, "标记在了还去读钥匙串，是每次启动都要付的代价")

        XCTAssertEqual(StoreInitializationMarker.updated(MetaFile(), inventory: inventory)?.storeInitialized, true)
        XCTAssertEqual(reads, 1)
    }

    /// 读不出来（锁着、没权限）不是「库是空的」，此时什么都不写。
    func test读不到库时不写标记() {
        XCTAssertNil(StoreInitializationMarker.updated(MetaFile(), inventory: { throw KeychainError.unexpectedData }))
    }
}
