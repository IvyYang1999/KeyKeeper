import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class CredentialGUIDataTests: XCTestCase {
    private var directory: URL!
    private var store: MetaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-gui-data-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MetaStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func test新增保存只调用注入Session并写Metadata() throws {
        let session = FakeCredentialSession()
        let vm = AddCredentialViewModel(session: session, store: store)
        vm.label = "Service"
        vm.credentialId = "service"
        vm.fields = [FieldEntry(name: "token", value: "opaque-value")]

        XCTAssertTrue(vm.save())
        XCTAssertEqual(session.operations, [
            .save(credentialId: "service", fieldName: "token", value: "opaque-value")
        ])
        XCTAssertEqual(try store.load().credentials["service"]?.label, "Service")
    }

    // 【曾经的 bug】新增入口即使绕过按钮验证也不能覆盖已有凭据。
    func test新增使用已有ID时拒绝且旧数据不变() throws {
        let existing = makeCredential(fields: [
            "old-token": CredentialField(secret: true)
        ])
        try store.save(MetaFile(credentials: ["service": existing]))
        let session = FakeCredentialSession(values: [
            "service.old-token": "opaque-old-value"
        ])
        let vm = AddCredentialViewModel(session: session, store: store)
        vm.label = "Replacement Service"
        vm.credentialId = "service"
        vm.fields = [FieldEntry(name: "new-token", value: "opaque-new-value")]

        XCTAssertFalse(vm.save())
        XCTAssertTrue(session.operations.isEmpty)
        XCTAssertEqual(session.values["service.old-token"], "opaque-old-value")
        XCTAssertEqual(
            Set(try store.load().credentials["service"]?.fields.keys.map { $0 } ?? []),
            ["old-token"]
        )
    }

    func test新增重复ID不尝试删除Vault且保留原Metadata() throws {
        let existing = makeCredential(fields: [
            "old-token": CredentialField(secret: true)
        ])
        try store.save(MetaFile(credentials: ["service": existing]))
        let session = FakeCredentialSession()
        session.errorForDelete = TestError.injectedFailure
        let vm = AddCredentialViewModel(session: session, store: store)
        vm.label = "Replacement Service"
        vm.credentialId = "service"
        vm.fields = [FieldEntry(name: "new-token", value: "opaque-new-value")]

        XCTAssertFalse(vm.save())
        XCTAssertTrue(session.operations.isEmpty)
        let stored = try XCTUnwrap(store.load().credentials["service"])
        XCTAssertEqual(stored.label, "Service")
        XCTAssertEqual(Set(stored.fields.keys), ["old-token"])
    }

    func test详情RevealCopy与编辑只调用注入Session() throws {
        let session = FakeCredentialSession(values: ["service.token": "opaque-value"])
        let credential = makeCredential(fields: ["token": CredentialField(secret: true)])
        try store.save(MetaFile(credentials: ["service": credential]))
        let vm = CredentialDetailViewModel(
            credentialId: "service",
            credential: credential,
            session: session,
            store: store
        )

        vm.toggleFieldVisibility(at: 0)
        XCTAssertEqual(vm.fields[0].value, "opaque-value")
        XCTAssertEqual(vm.copyFieldValue("token"), "opaque-value")
        vm.fields[0].value = "replacement-value"
        XCTAssertTrue(vm.saveChanges())

        XCTAssertEqual(session.operations, [
            .retrieve(credentialId: "service", fieldName: "token"),
            .retrieve(credentialId: "service", fieldName: "token"),
            .save(credentialId: "service", fieldName: "token", value: "replacement-value")
        ])
    }

    func testFileDetailsNeverRevealAndMetadataEditPreservesType() throws {
        let session = FakeCredentialSession(values: ["service.json": "synthetic-file"])
        let credential = makeCredential(fields: ["json": .init(secret: true, fileFormat: .serviceAccountJSON)])
        try store.save(.init(credentials: ["service": credential]))
        let vm = CredentialDetailViewModel(credentialId: "service", credential: credential, session: session, store: store)
        vm.toggleFieldVisibility(at: 0)
        XCTAssertNil(vm.copyFieldValue("json"))
        XCTAssertTrue(session.operations.isEmpty)
        vm.credential.notes = "New description"
        XCTAssertTrue(vm.saveChanges())
        XCTAssertEqual(try store.load().credentials["service"]?.fields["json"]?.fileFormat, .serviceAccountJSON)
        XCTAssertTrue(session.operations.isEmpty)
        XCTAssertTrue(CredentialUsageCopy.runCommand(credentialId: "service", credential: credential).contains("--file service:json=GOOGLE_APPLICATION_CREDENTIALS"))
        XCTAssertEqual(CredentialUsageCopy.environmentNames(for: credential), [])
        vm.fields.append(.init(name: "json", value: "not-a-file"))
        XCTAssertFalse(vm.saveChanges(), "Duplicate text fields cannot replace a file")
        XCTAssertTrue(session.operations.isEmpty)
    }

    func testLocked时SaveRevealCopyDelete均提示Unlock且Metadata完好() throws {
        let existing = makeCredential(fields: ["token": CredentialField(secret: true)])
        try store.save(MetaFile(credentials: ["existing": existing]))
        let session = FakeCredentialSession(status: .locked)

        let addVM = AddCredentialViewModel(session: session, store: store)
        addVM.label = "New"
        addVM.credentialId = "new"
        addVM.fields = [FieldEntry(name: "token", value: "opaque-new-value")]
        XCTAssertFalse(addVM.save())
        XCTAssertTrue(addVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)

        let detailVM = CredentialDetailViewModel(
            credentialId: "existing",
            credential: existing,
            session: session,
            store: store
        )
        detailVM.toggleFieldVisibility(at: 0)
        XCTAssertTrue(detailVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)
        XCTAssertNil(detailVM.copyFieldValue("token"))
        XCTAssertTrue(detailVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)
        detailVM.fields.removeAll()
        XCTAssertFalse(detailVM.saveChanges())
        XCTAssertTrue(detailVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)

        let listVM = CredentialListViewModel(session: session, store: store)
        XCTAssertFalse(listVM.delete(id: "existing"))
        XCTAssertTrue(listVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)

        let meta = try store.load()
        XCTAssertNil(meta.credentials["new"])
        XCTAssertEqual(
            Set(meta.credentials["existing"]?.fields.keys.map { $0 } ?? []),
            ["token"]
        )
        XCTAssertEqual(session.operations, [])
    }

    func test编辑移除Secret先删除Vault再提交Metadata() throws {
        let existing = makeCredential(fields: [
            "kept": CredentialField(secret: true),
            "removed": CredentialField(secret: true)
        ])
        try store.save(MetaFile(credentials: ["service": existing]))
        let session = FakeCredentialSession()
        session.onOperation = { [store] operation in
            guard case .delete = operation else { return }
            XCTAssertNotNil(try store?.load().credentials["service"]?.fields["removed"])
        }
        let vm = CredentialDetailViewModel(
            credentialId: "service",
            credential: existing,
            session: session,
            store: store
        )
        vm.fields.removeAll { $0.name == "removed" }

        XCTAssertTrue(vm.saveChanges())
        XCTAssertEqual(session.operations, [
            .delete(credentialId: "service", fieldName: "removed")
        ])
        XCTAssertNil(try store.load().credentials["service"]?.fields["removed"])
    }

    func test删除凭据Vault失败则Metadata保留() throws {
        let existing = makeCredential(fields: ["token": CredentialField(secret: true)])
        try store.save(MetaFile(credentials: ["service": existing]))
        let session = FakeCredentialSession()
        session.errorForDelete = TestError.injectedFailure
        let vm = CredentialListViewModel(session: session, store: store)

        XCTAssertFalse(vm.delete(id: "service"))
        XCTAssertNotNil(try store.load().credentials["service"])
        XCTAssertEqual(session.operations, [
            .delete(credentialId: "service", fieldName: "token")
        ])
    }

    func test删除凭据先删完Vault再删除Metadata() throws {
        let existing = makeCredential(fields: [
            "a": CredentialField(secret: true),
            "b": CredentialField(secret: true)
        ])
        try store.save(MetaFile(credentials: ["service": existing]))
        let session = FakeCredentialSession()
        session.onOperation = { [store] operation in
            guard case .delete = operation else { return }
            XCTAssertNotNil(try store?.load().credentials["service"])
        }
        let vm = CredentialListViewModel(session: session, store: store)

        XCTAssertTrue(vm.delete(id: "service"))
        XCTAssertEqual(session.operations, [
            .delete(credentialId: "service", fieldName: "a"),
            .delete(credentialId: "service", fieldName: "b")
        ])
        XCTAssertNil(try store.load().credentials["service"])
    }

    /// 打开详情不读值；显式取摘要时只读一次文件字段，文本字段不走这条路，界面上的值仍为空。
    func test服务账号详情只读出邮箱和项目编号() throws {
        let json = #"{"type":"service_account","project_id":"ga4-demo","client_email":"bot@ga4-demo.iam.gserviceaccount.com","private_key":"synthetic"}"#
        let session = FakeCredentialSession(values: ["service.json": json, "service.token": "opaque"])
        let credential = makeCredential(fields: [
            "json": .init(secret: true, fileFormat: .serviceAccountJSON),
            "token": .init(secret: true),
        ])
        try store.save(.init(credentials: ["service": credential]))
        let vm = CredentialDetailViewModel(credentialId: "service", credential: credential, session: session, store: store)
        XCTAssertTrue(session.operations.isEmpty)

        let summary = vm.serviceAccountSummary(fieldName: "json")
        XCTAssertEqual(summary?.clientEmail, "bot@ga4-demo.iam.gserviceaccount.com")
        XCTAssertEqual(summary?.projectId, "ga4-demo")
        XCTAssertEqual(session.operations, [.retrieve(credentialId: "service", fieldName: "json")])
        XCTAssertNil(vm.serviceAccountSummary(fieldName: "token"))
        XCTAssertEqual(session.operations.count, 1)
        XCTAssertEqual(vm.fields.first { $0.name == "json" }?.value, "", "文件内容不能进入界面字段")
    }

    /// 新增时字段名随手起（"API Key "），存成机器名 api-key，原样的写法记成显示名。
    func test新增时随手起的字段名变机器名并记成显示名() throws {
        let session = FakeCredentialSession()
        let vm = AddCredentialViewModel(session: session, store: store)
        vm.label = "百度千帆"
        vm.autoGenerateId()
        XCTAssertEqual(vm.credentialId, "bai-du-qian-fan")
        vm.fields = [FieldEntry(name: "API Key ", value: "v1"), FieldEntry(name: "region", value: "v2")]
        XCTAssertEqual(AddCredentialViewModel.machineFieldName("API Key "), "api-key")
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let credential = try XCTUnwrap(store.load().credentials["bai-du-qian-fan"])
        XCTAssertEqual(credential.fields["api-key"]?.displayName, "API Key")
        XCTAssertNil(credential.fields["region"]?.displayName)
        XCTAssertEqual(session.values["bai-du-qian-fan.api-key"], "v1")

        let clash = AddCredentialViewModel(session: session, store: store)
        clash.label = "Clash"
        clash.autoGenerateId()
        clash.fields = [FieldEntry(name: "API Key", value: "a"), FieldEntry(name: "api-key", value: "b")]
        XCTAssertFalse(clash.save(), "规整后撞名要拒绝")
    }

    /// 编辑时可以改显示名和组 ID；组 ID 改名走不丢值的三步，旧名进 aliases。
    func test编辑时改显示名和组ID() throws {
        let session = FakeCredentialSession(values: ["svc.token": "opaque"])
        let credential = makeCredential(fields: ["token": CredentialField(secret: true)])
        try store.save(.init(credentials: ["svc": credential]))
        let vm = CredentialDetailViewModel(credentialId: "svc", credential: credential, session: session, store: store)
        vm.isEditing = true
        vm.fields[0].displayName = "Deploy token"
        vm.groupIdDraft = "service"

        XCTAssertTrue(vm.saveChanges(), vm.errorMessage ?? "")
        XCTAssertEqual(vm.renamedGroupId, "service")
        let saved = try XCTUnwrap(store.load().credentials["service"])
        XCTAssertEqual(saved.aliases, ["svc"])
        XCTAssertEqual(saved.fields["token"]?.displayName, "Deploy token")
        XCTAssertEqual(session.values["service.token"], "opaque")
        XCTAssertNil(try store.load().credentials["svc"])

        let bad = CredentialDetailViewModel(credentialId: "service", credential: saved, session: session, store: store)
        bad.isEditing = true
        bad.groupIdDraft = "Not Valid"
        XCTAssertFalse(bad.saveChanges())
        XCTAssertNotNil(bad.errorMessage)
    }

    /// 界面改字段名：新名要合规则；改名后后台授权跟着新名走，不再悄悄失效。
    func test编辑改字段名要合规则且后台授权跟着走() throws {
        let session = FakeCredentialSession(values: ["svc.token": "opaque"])
        let credential = makeCredential(fields: ["token": CredentialField(secret: true)])
        try store.save(.init(credentials: ["svc": credential]))
        let grants = ServiceGrantStore(directory: directory)
        try grants.addGrant(ServiceGrant(credentialId: "svc", subjectFingerprint: "fp", subjectDisplayName: "cron",
                                         fields: ["token"], duration: .always))

        let invalid = CredentialDetailViewModel(credentialId: "svc", credential: credential, session: session, store: store)
        invalid.isEditing = true
        invalid.fields[0].name = "deploy token"
        XCTAssertFalse(invalid.saveChanges())

        let vm = CredentialDetailViewModel(credentialId: "svc", credential: credential, session: session, store: store)
        vm.isEditing = true
        vm.fields[0].name = "deploy-token"
        XCTAssertTrue(vm.saveChanges(), vm.errorMessage ?? "")
        XCTAssertEqual(try store.load().credentials["svc"]?.fields["deploy-token"]?.aliases, ["token"])
        XCTAssertEqual(try grants.grants(credentialId: "svc").map(\.fields), [["deploy-token"]])
    }

    private func makeCredential(fields: [String: CredentialField]) -> Credential {
        Credential(
            label: "Service",
            notes: "",
            links: [],
            fields: fields,
            security: .strict,
            created: "2026-07-20",
            updated: "2026-07-20"
        )
    }

    // 【曾经的 bug】一个旧字段缺失不应阻止无关的新凭据入库。
    func testPartialOldStoreAllowsNewCredentialWithoutChangingOldValuesOrMetadata() throws {
        let old = makeCredential(fields: ["missing": .init(secret: true), "kept": .init(secret: true)])
        try store.save(.init(credentials: ["old": old]))
        let io = GUIRecoveryBlobIO()
        io.blob = Data(#"{"version":1,"credentials":{"old":{"kept":"synthetic-kept","orphan":"synthetic-orphan"}}}"#.utf8)
        let session = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.store.load() }))
        let vm = AddCredentialViewModel(session: session, store: store)
        vm.label = "New"; vm.credentialId = "new"
        vm.fields = [.init(name: "a", value: "synthetic-a"), .init(name: "b", value: "synthetic-b")]
        XCTAssertTrue(vm.save())
        XCTAssertEqual(io.writeCount, 1, "Multi-field create must be one Keychain write")
        XCTAssertEqual(try session.retrieve(credentialId: "new", fieldName: "a"), "synthetic-a")
        XCTAssertEqual(try session.retrieve(credentialId: "new", fieldName: "b"), "synthetic-b")
        XCTAssertEqual(try session.retrieve(credentialId: "old", fieldName: "kept"), "synthetic-kept")
        XCTAssertEqual(try session.retrieve(credentialId: "old", fieldName: "orphan"), "synthetic-orphan")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(store.load().credentials["old"]), try encoder.encode(old))
        XCTAssertThrowsError(try session.validateStorage(), "Editing/deleting protection remains")
    }
}

extension CredentialGUIDataTests {
    func testNewSaveBlocksMissingStoreOrOrphanCollisionWithoutChangingMetadata() throws {
        let old = makeCredential(fields: ["missing": .init(secret: true)])
        try store.save(.init(credentials: ["old": old]))
        let before = try Data(contentsOf: store.fileURL)
        let originals: [Data?] = [nil, Data("invalid".utf8), Data(#"{"version":1,"credentials":{"new":{"other":"synthetic"}}}"#.utf8)]
        for original in originals {
            let io = GUIRecoveryBlobIO(); io.blob = original
            let service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.store.load() }))
            let vm = AddCredentialViewModel(session: service, store: store)
            vm.label = "New"; vm.credentialId = "new"; vm.fields = [.init(name: "fixture", value: "synthetic")]
            XCTAssertFalse(vm.save())
            XCTAssertEqual(io.blob, original); XCTAssertEqual(io.writeCount, 0)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        }
    }

    func testCreateRechecksFreshMetadataAndRejectsDuplicateFieldsAndOldReadGrants() throws {
        let service = FakeCredentialSession()
        let vm = AddCredentialViewModel(session: service, store: store)
        vm.label = "New"; vm.credentialId = "new"; vm.fields = [.init(name: "fixture", value: "synthetic")]
        try store.save(.init(credentials: ["new": makeCredential(fields: [:])]))
        XCTAssertFalse(vm.save()); XCTAssertTrue(service.operations.isEmpty)
        try store.save(.init())
        vm.fields.append(.init(name: "fixture", value: "other"))
        XCTAssertFalse(vm.save()); XCTAssertTrue(service.operations.isEmpty)
        vm.fields.removeLast()
        try GrantStore(directory: directory).addGrant(.init(credentialId: "new", duration: .always))
        XCTAssertFalse(vm.save()); XCTAssertTrue(service.operations.isEmpty)
        XCTAssertNil(try store.load().credentials["new"])
    }

    func testMetadataCommitFailureRetainsStoredValuesAndReportsDoNotRetry() throws {
        let io = GUIRecoveryBlobIO()
        let service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.store.load() }))
        io.onWrite = { try FileManager.default.createDirectory(at: self.store.fileURL, withIntermediateDirectories: false) }
        let vm = AddCredentialViewModel(session: service, store: store)
        vm.label = "New"; vm.credentialId = "new"; vm.fields = [.init(name: "fixture", value: "synthetic")]
        XCTAssertFalse(vm.save())
        XCTAssertTrue(vm.errorMessage?.contains("Do not retry") == true)
        XCTAssertEqual(try service.retrieve(credentialId: "new", fieldName: "fixture"), "synthetic")
        XCTAssertEqual(io.writeCount, 1)
        XCTAssertFalse(vm.save()); XCTAssertEqual(io.writeCount, 1)
    }
}

private final class GUIRecoveryBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var writeCount = 0
    var onWrite: (() throws -> Void)?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        guard !replacingExisting || blob != nil else { throw CredentialStorageError.missingStore }
        blob = data; writeCount += 1
        try onWrite?()
    }
}

private final class FakeCredentialSession: CredentialSessionManaging {
    var currentStatus: SessionStatus
    var values: [String: String]
    var errorForDelete: Error?
    var onOperation: ((SessionOperation) throws -> Void)?
    private(set) var operations: [SessionOperation] = []

    init(status: SessionStatus = .unlocked(expiresAt: nil), values: [String: String] = [:]) {
        currentStatus = status
        self.values = values
    }

    func status() -> SessionStatus {
        currentStatus
    }

    func createCredential(credentialId: String, values: [String: String], security: SecurityLevel) throws {
        for (name, value) in values.sorted(by: { $0.key < $1.key }) {
            try save(credentialId: credentialId, fieldName: name, value: value, security: security)
        }
    }

    func copyValues(fromCredentialId: String, toCredentialId: String, fieldMap: [String: String]) throws {
        for (key, value) in values where key.hasPrefix("\(fromCredentialId).") {
            let field = String(key.dropFirst(fromCredentialId.count + 1))
            values["\(toCredentialId).\(fieldMap[field] ?? field)"] = value
        }
    }

    func dropValues(credentialId: String, fieldNames: [String]) throws {
        for field in fieldNames { values.removeValue(forKey: "\(credentialId).\(field)") }
    }

    func retrieve(credentialId: String, fieldName: String) throws -> String {
        guard case .unlocked = currentStatus else { throw SessionManagerError.locked }
        let operation = SessionOperation.retrieve(credentialId: credentialId, fieldName: fieldName)
        operations.append(operation)
        try onOperation?(operation)
        return values["\(credentialId).\(fieldName)"] ?? ""
    }

    func save(credentialId: String, fieldName: String, value: String, security: SecurityLevel) throws {
        guard case .unlocked = currentStatus else { throw SessionManagerError.locked }
        let operation = SessionOperation.save(
            credentialId: credentialId,
            fieldName: fieldName,
            value: value
        )
        operations.append(operation)
        try onOperation?(operation)
        values["\(credentialId).\(fieldName)"] = value
    }

    func delete(credentialId: String, fieldName: String) throws {
        guard case .unlocked = currentStatus else { throw SessionManagerError.locked }
        let operation = SessionOperation.delete(credentialId: credentialId, fieldName: fieldName)
        operations.append(operation)
        try onOperation?(operation)
        if let errorForDelete { throw errorForDelete }
        values.removeValue(forKey: "\(credentialId).\(fieldName)")
    }
}

private enum SessionOperation: Equatable {
    case retrieve(credentialId: String, fieldName: String)
    case save(credentialId: String, fieldName: String, value: String)
    case delete(credentialId: String, fieldName: String)
}

private enum TestError: Error {
    case injectedFailure
}

extension CredentialGUIDataTests {
    /// 【曾经的 bug】label 重名生成同一 ID，保存直接覆盖旧凭据的 meta 与 vault 值，无任何提示。
    func test曾经的Bug重复ID被拦截不再静默覆盖() throws {
        try store.save(MetaFile(credentials: [
            "stripe": makeCredential(fields: ["token": CredentialField(secret: true)])
        ]))
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.label = "Stripe"
        vm.autoGenerateId()
        vm.fields = [FieldEntry(name: "token", value: "new-value")]

        XCTAssertEqual(vm.credentialId, "stripe")
        XCTAssertNotNil(vm.idProblem)
        XCTAssertTrue(vm.idProblem?.contains("already exists") ?? false)
        XCTAssertFalse(vm.isValid)

        vm.userEditedId("stripe-test")
        XCTAssertNil(vm.idProblem)
        XCTAssertTrue(vm.isValid)
    }

    func test符号或空格名字生成空ID时不可保存() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.label = "!!! ???"
        vm.autoGenerateId()
        vm.fields = [FieldEntry(name: "token", value: "value")]
        XCTAssertEqual(vm.credentialId, "")
        XCTAssertNotNil(vm.idProblem)
        XCTAssertFalse(vm.isValid)
    }

    func test手动输入ID会被规整为小写连字符() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.userEditedId("My Service 2")
        XCTAssertEqual(vm.credentialId, "my-service-2")
        // 组 ID 给机器用：中文转拼音，只留 ASCII（yyt 2026-09-11）。
        XCTAssertEqual(AddCredentialViewModel.sanitizeId("飞搜 API"), "fei-sou-api")
    }

    func test草稿标题在未填名字时给出占位() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        XCTAssertEqual(vm.draftTitle, "(untitled)")
        vm.label = "OpenAI"
        XCTAssertEqual(vm.draftTitle, "OpenAI")
    }
}

extension CredentialGUIDataTests {
    func test深链预填名字字段并生成ID() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.label = "old draft"
        vm.prefill(label: "Feishu Bot", fields: ["app-id", "app-secret"], notes: "from agent")

        XCTAssertEqual(vm.label, "Feishu Bot")
        XCTAssertEqual(vm.credentialId, "feishu-bot")
        XCTAssertEqual(vm.fields.map(\.name), ["app-id", "app-secret"])
        XCTAssertTrue(vm.fields.allSatisfy { $0.value.isEmpty })
        XCTAssertEqual(vm.notes, "from agent")
        XCTAssertFalse(vm.isValid, "values still have to be pasted by the user")
    }

    func test深链没有字段时保留一个空行() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.prefill(label: nil, fields: [], notes: nil)
        XCTAssertEqual(vm.fields.count, 1)
        XCTAssertEqual(vm.label, "")
    }
}

extension CredentialGUIDataTests {
    func test新表单预填默认字段名且不算草稿() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        XCTAssertEqual(vm.fields.map(\.name), [AddCredentialViewModel.defaultFieldName])
        XCTAssertFalse(vm.hasDraft, "预填的默认字段名不该让列表显示草稿提示")

        vm.label = "OpenAI"
        XCTAssertTrue(vm.hasDraft)
        vm.reset()
        XCTAssertFalse(vm.hasDraft)
        XCTAssertEqual(vm.fields.map(\.name), [AddCredentialViewModel.defaultFieldName])
    }

    func test改字段名或填值都算草稿() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.fields = [FieldEntry(name: AddCredentialViewModel.defaultFieldName, value: "v")]
        XCTAssertTrue(vm.hasDraft)

        let renamed = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        renamed.fields = [FieldEntry(name: "token")]
        XCTAssertTrue(renamed.hasDraft)

        let extra = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        extra.fields = [FieldEntry(name: AddCredentialViewModel.defaultFieldName), FieldEntry()]
        XCTAssertTrue(extra.hasDraft)
    }

    func testID摘要给出用户真正要敲的命令() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        XCTAssertEqual(vm.idSummary, "The ID is created from the name")
        vm.label = "OpenAI"
        vm.autoGenerateId()
        XCTAssertEqual(vm.idSummary, "openai · keykeeper run -c openai")
    }

    func test重复ID既是冲突也仍然拦截保存() throws {
        try store.save(MetaFile(credentials: [
            "stripe": makeCredential(fields: ["token": CredentialField(secret: true)])
        ]))
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.label = "Stripe"
        vm.autoGenerateId()
        vm.fields = [FieldEntry(name: "token", value: "v")]

        // 冲突单独暴露出来，好让界面给「打开它」而不是一段红字
        XCTAssertEqual(vm.conflictingId, "stripe")
        XCTAssertNil(vm.idFormatProblem)
        XCTAssertFalse(vm.isValid)

        vm.userEditedId("stripe-test")
        XCTAssertNil(vm.conflictingId)
        XCTAssertTrue(vm.isValid)
    }

    func test格式问题与冲突分开报告() {
        let vm = AddCredentialViewModel(session: FakeCredentialSession(), store: store)
        vm.label = "!!! ???"
        vm.autoGenerateId()
        XCTAssertEqual(vm.credentialId, "")
        XCTAssertNotNil(vm.idFormatProblem)
        XCTAssertNil(vm.conflictingId)
    }
}
