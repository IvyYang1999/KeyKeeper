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

    func test新增使用已有ID时先清理被覆盖的Vault字段() throws {
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

        XCTAssertTrue(vm.save())
        XCTAssertEqual(session.operations, [
            .delete(credentialId: "service", fieldName: "old-token"),
            .save(
                credentialId: "service",
                fieldName: "new-token",
                value: "opaque-new-value"
            )
        ])
        XCTAssertNil(session.values["service.old-token"])
        XCTAssertEqual(
            Set(try store.load().credentials["service"]?.fields.keys.map { $0 } ?? []),
            ["new-token"]
        )
    }

    func test新增覆盖时Vault删除失败则保留原Metadata() throws {
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
        XCTAssertEqual(session.operations, [
            .delete(credentialId: "service", fieldName: "old-token")
        ])
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

    func testIPC锁定同一Session后GUI立即读取失败() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age") &&
                FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age-keygen"),
            "The system age executables are unavailable."
        )
        let vault = AgeVaultStore(directory: directory)
        _ = try vault.initVault(passphrase: "session phrase placeholder")
        try vault.save(
            credentialId: "service",
            fieldName: "token",
            value: "shared-session-value",
            security: .standard
        )
        let manager = SessionManager(directory: directory, lockPolicy: .untilManualOrReboot)
        try manager.unlock(passphrase: "session phrase placeholder")
        let credential = try XCTUnwrap(store.load().credentials["service"])
        let detailVM = CredentialDetailViewModel(
            credentialId: "service",
            credential: credential,
            session: manager,
            store: store
        )
        let server = IPCServer(session: manager)

        detailVM.toggleFieldVisibility(at: 0)
        XCTAssertEqual(detailVM.fields[0].value, "shared-session-value")
        detailVM.toggleFieldVisibility(at: 0)

        XCTAssertTrue(server.handleSessionControl(SessionControlRequest(action: .lock)).success)
        detailVM.toggleFieldVisibility(at: 0)
        XCTAssertFalse(detailVM.fields[0].visible)
        XCTAssertTrue(detailVM.errorMessage?.localizedCaseInsensitiveContains("unlock") == true)
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
        XCTAssertEqual(AddCredentialViewModel.sanitizeId("飞搜 API"), "飞搜-api")
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
