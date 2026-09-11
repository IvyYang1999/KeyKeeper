import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 【曾经的 bug】2026-09-11 yyt：编辑一个条目时，如果没先点小眼睛，原密钥值会丢。
/// 两条路径：改字段名后保存会删掉值；编辑态的小眼睛只切换显示、不去取值，看起来是空的。
@MainActor
final class CredentialEditValueLossTests: XCTestCase {
    private func makeVM(values: [String: String]) throws -> (CredentialDetailViewModel, EditLossSession, MetaStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MetaStore(directory: dir)
        let credential = Credential(label: "Stripe", notes: "", links: [],
                                    fields: ["Secret key": CredentialField(secret: true)],
                                    security: .standard, created: "2026-09-01", updated: "2026-09-01")
        try store.save(MetaFile(credentials: ["stripe": credential]))
        let session = EditLossSession(values: values)
        let vm = CredentialDetailViewModel(credentialId: "stripe", credential: credential, session: session, store: store)
        return (vm, session, store)
    }

    func test曾经的Bug未揭示直接改字段名保存值不丢() throws {
        let (vm, session, store) = try makeVM(values: ["stripe.Secret key": "sk_live_synthetic"])
        vm.isEditing = true
        vm.fields[0].name = "secret-key"

        XCTAssertTrue(vm.saveChanges())

        XCTAssertEqual(session.values["stripe.secret-key"], "sk_live_synthetic")
        XCTAssertNil(session.values["stripe.Secret key"])
        XCTAssertEqual(try store.load().credentials["stripe"]?.fields.keys.sorted(), ["secret-key"])
    }

    func test未揭示直接保存值保留() throws {
        let (vm, session, _) = try makeVM(values: ["stripe.Secret key": "sk_live_synthetic"])
        vm.isEditing = true
        XCTAssertTrue(vm.saveChanges())
        XCTAssertEqual(session.values["stripe.Secret key"], "sk_live_synthetic")
    }

    func test曾经的Bug编辑器里点眼睛会取出已存的值() throws {
        let (vm, session, _) = try makeVM(values: ["stripe.Secret key": "sk_live_synthetic"])
        vm.isEditing = true

        try KeyFieldsEditor.toggleVisibility(of: &vm.fields, at: 0) { entry in
            try session.retrieve(credentialId: "stripe", fieldName: entry.name)
        }

        XCTAssertTrue(vm.fields[0].visible)
        XCTAssertEqual(vm.fields[0].value, "sk_live_synthetic")
    }

    func test新增页的眼睛不去取值() throws {
        var fields = [FieldEntry(name: "api-key")]
        var fetched = false
        try KeyFieldsEditor.toggleVisibility(of: &fields, at: 0) { _ in fetched = true; return "x" }
        XCTAssertFalse(fetched, "没有已存值的字段只切换显示")
        XCTAssertTrue(fields[0].visible)
    }
}

private final class EditLossSession: CredentialSessionManaging {
    var values: [String: String]
    init(values: [String: String]) { self.values = values }
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func createCredential(credentialId: String, values newValues: [String: String], security: SecurityLevel) throws {
        for (field, value) in newValues { values["\(credentialId).\(field)"] = value }
    }
    func retrieve(credentialId: String, fieldName: String) throws -> String {
        guard let value = values["\(credentialId).\(fieldName)"] else { throw KeychainError.notFound }
        return value
    }
    func save(credentialId: String, fieldName: String, value: String, security: SecurityLevel) throws {
        values["\(credentialId).\(fieldName)"] = value
    }
    func delete(credentialId: String, fieldName: String) throws {
        values.removeValue(forKey: "\(credentialId).\(fieldName)")
    }
}
