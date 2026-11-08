import AppKit
import SwiftUI
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

/// 【曾经的 bug】2026-11-07 yyt：编辑一把已有的 key，新加两个字段，把「Access Token」这种带空格的
/// 名字填进显示名、名称留空，保存不报错，可两个字段连同粘贴的值一起消失了；填进名称又报「只能用字母、
/// 数字……」，底下明明已经生成了合法写法却不替换。编辑页现在只让人写一个名字，字段名自动生成。
@MainActor
final class CredentialEditorNamingTests: XCTestCase {
    private func makeVM(fields: [String: CredentialField] = ["consumer-key": .init(secret: true)],
                        values: [String: String] = ["x.consumer-key": "ck-synthetic-0001"])
        throws -> (CredentialDetailViewModel, NamingSession, MetaStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = MetaStore(directory: dir)
        let credential = Credential(label: "X", notes: "", links: [], fields: fields,
                                    security: .standard, created: "2026-11-01", updated: "2026-11-01")
        try store.save(MetaFile(credentials: ["x": credential]))
        let session = NamingSession(values: values)
        let vm = CredentialDetailViewModel(credentialId: "x", credential: credential, session: session,
                                           store: store, approvals: .inMemory())
        return (vm, session, store)
    }

    /// 【曾经的 bug】名字只写在显示名里、字段名留空：原来整行被跳过，值丢了也不报错。
    func test曾经的Bug只填显示名的新字段保存后还在() throws {
        let (vm, session, store) = try makeVM()
        vm.beginEditing()
        var row = FieldEntry()
        row.displayName = "Access Token"
        row.value = "at-synthetic-0002"
        vm.fields.append(row)

        XCTAssertTrue(vm.saveChanges(), vm.errorMessage ?? "")

        let saved = try XCTUnwrap(store.load().credentials["x"])
        XCTAssertEqual(saved.fields["access-token"]?.displayName, "Access Token")
        XCTAssertEqual(session.values["x.access-token"], "at-synthetic-0002")
        XCTAssertEqual(session.values["x.consumer-key"], "ck-synthetic-0001", "已有的值不受影响")
    }

    /// 【曾经的 bug】名字带空格：不再报错让人重填，直接换成预览里那个写法，原文留作显示名。
    func test曾经的Bug名称带空格时自动换成合法字段名() throws {
        let (vm, session, store) = try makeVM()
        vm.beginEditing()
        var row = FieldEntry()
        row.name = "Access Token Secret"
        row.value = "ats-synthetic-0003"
        vm.fields.append(row)

        XCTAssertTrue(vm.saveChanges(), vm.errorMessage ?? "")

        let saved = try XCTUnwrap(store.load().credentials["x"])
        XCTAssertEqual(saved.fields["access-token-secret"]?.displayName, "Access Token Secret")
        XCTAssertEqual(session.values["x.access-token-secret"], "ats-synthetic-0003")
    }

    /// 有值却没有任何名字：宁可不保存，也要指出是哪一行；什么都不写。
    func test有值没名字的行不保存并指出是哪一行() throws {
        let (vm, session, store) = try makeVM()
        vm.beginEditing()
        var row = FieldEntry()
        row.value = "orphan-synthetic-0004"
        vm.fields.append(row)
        let before = session.values

        XCTAssertFalse(vm.saveChanges())

        XCTAssertNotNil(vm.fieldErrors[row.id], "错误要落在那一行上")
        XCTAssertEqual(session.values, before)
        XCTAssertEqual(try store.load().credentials["x"]?.fields.keys.sorted(), ["consumer-key"])
    }

    /// 生成出来的字段名和已有字段撞了：指出那一行，不悄悄覆盖、不写入。
    func test生成的字段名和已有字段重名时指出那一行() throws {
        let (vm, session, _) = try makeVM()
        vm.beginEditing()
        var row = FieldEntry()
        row.setTitle("Consumer Key")
        row.value = "dup-synthetic-0005"
        vm.fields.append(row)

        XCTAssertFalse(vm.saveChanges())

        XCTAssertNotNil(vm.fieldErrors[row.id])
        XCTAssertEqual(session.values["x.consumer-key"], "ck-synthetic-0001", "已有的值不能被新行覆盖")
    }

    /// 改已有字段的名字只改显示名：脚本和授权里写的字段名不变。
    func test已有字段改名字只改显示名() throws {
        var field = FieldEntry(name: "consumer-key", existingSecret: true, originalName: "consumer-key")
        field.setTitle("Consumer Key")
        XCTAssertEqual(field.name, "consumer-key")
        XCTAssertEqual(field.displayName, "Consumer Key")
        XCTAssertEqual(field.title, "Consumer Key")
        field.setTitle("consumer-key")
        XCTAssertEqual(field.displayName, "", "和字段名一样就不另存显示名")
    }

    /// 新字段的字段名跟着名字走；手动改过字段名之后，再改名字就不去动它。
    func test新字段的字段名跟着名字走直到手动改过() {
        var field = FieldEntry()
        field.setTitle("Access Token")
        XCTAssertEqual(field.name, "access-token")
        XCTAssertEqual(field.displayName, "Access Token")
        field.setTitle("api_key")
        XCTAssertEqual(field.name, "api_key")
        XCTAssertEqual(field.displayName, "")
        field.setMachineName("token")
        field.setTitle("Bearer Token")
        XCTAssertEqual(field.name, "token")
        XCTAssertEqual(field.displayName, "Bearer Token")
    }

    /// 「未修改」什么都看不出：进编辑时给已存的值一个遮罩预览，缺值的直接标出来；明文不留在表单里。
    func test进入编辑时已存的值显示遮罩预览() throws {
        let (vm, _, _) = try makeVM(fields: ["consumer-key": .init(secret: true), "access-token": .init(secret: true)],
                                    values: ["x.consumer-key": "ck-synthetic-0001"])
        vm.beginEditing()

        let key = try XCTUnwrap(vm.fields.first { $0.name == "consumer-key" })
        XCTAssertEqual(key.storedPreview, "\u{2022}\u{2022}\u{2022}\u{2022} 0001", "用户 2026-11-08 定：只露后 4 位")
        XCTAssertEqual(key.value, "", "预览不是值：不保存就不会重写")
        let token = try XCTUnwrap(vm.fields.first { $0.name == "access-token" })
        XCTAssertTrue(token.storedMissing)
        XCTAssertNil(token.storedPreview)
    }

    /// 添加页同样不能把「有值没名字」的那一行悄悄丢掉。
    func test添加页有值没名字的行不保存() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = MetaStore(directory: dir)
        let vm = AddCredentialViewModel(session: KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO())),
                                        store: store, approvals: .inMemory())
        vm.label = "X"; vm.autoGenerateId()
        vm.fields = [FieldEntry(name: "api-key", value: "sk-synthetic-0006"), FieldEntry(value: "sk-synthetic-0007")]
        let orphan = vm.fields[1].id

        XCTAssertFalse(vm.save())

        XCTAssertNotNil(vm.fieldErrors[orphan])
        XCTAssertNil(try store.load().credentials["x"], "一个都不写")
    }

    /// 【曾经的 bug】2026-11-08 主力 Mac 验收 follow-up：添加页拒绝保存时说「见标红的那几行」，
    /// 可哪一行都没标，因为添加页没把行错误交给密钥列表。
    func test曾经的Bug添加页拒绝保存时错误标在那一行上() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let vm = AddCredentialViewModel(session: KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO())),
                                        store: MetaStore(directory: dir), approvals: .inMemory())
        vm.label = "X"; vm.autoGenerateId()
        vm.fields = [FieldEntry(name: "api-key", value: "sk-synthetic-0008"), FieldEntry(value: "sk-synthetic-0009")]
        XCTAssertFalse(vm.save())

        XCTAssertNotNil(vm.errorMessage)
        let rowErrors = vm.fieldErrors
        XCTAssertEqual(rowErrors.count, 1)

        // Same page, same summary line; only the row error differs. A shown row error takes a line.
        _ = NSApplication.shared
        func height() -> CGFloat {
            let view = NSHostingView(rootView: AddCredentialView(
                vm: vm, onSave: {}, onCancel: {}, onOpenExisting: { _ in }, onImportFile: nil
            ).environment(\.panelLayout, .popover))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        let marked = height()
        vm.fieldErrors = [:]
        let unmarked = height()
        XCTAssertGreaterThan(marked, unmarked + 8, "出错的那一行要显示错误")
    }
}

final class NamingSession: CredentialSessionManaging {
    var values: [String: String]
    init(values: [String: String]) { self.values = values }
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
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
    func storedFieldNames(credentialId: String) throws -> Set<String> {
        Set(values.keys.filter { $0.hasPrefix(credentialId + ".") }.map { String($0.dropFirst(credentialId.count + 1)) })
    }
}
