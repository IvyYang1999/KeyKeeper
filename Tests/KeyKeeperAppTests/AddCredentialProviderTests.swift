import XCTest
import CryptoKit
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor final class AddCredentialProviderTests: XCTestCase {
    private func fixture() throws -> (AddCredentialViewModel, MetaStore, KeychainCredentialService) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = MetaStore(directory: dir)
        let session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
        return (AddCredentialViewModel(session: session, store: store, approvals: .inMemory()), store, session)
    }

    func test模板填充完整字段并保存绑定及别名() throws {
        let (vm, store, _) = try fixture()
        XCTAssertTrue(vm.selectProvider("zhipu"))
        let template = try XCTUnwrap(ProviderCatalog.find("zhipu"))
        XCTAssertEqual(vm.providerID, template.id)
        XCTAssertEqual(vm.fields.map(\.name), template.fields.map(\.name))
        XCTAssertEqual(vm.label, template.name)
        XCTAssertFalse(vm.isValid)
        vm.fields[0].value = "synthetic-provider-key"
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        XCTAssertEqual(saved.provider, template.id)
        XCTAssertEqual(saved.fields[template.fieldName]?.aliases, template.primaryField.aliases)
        XCTAssertNil(saved.fields[template.fieldName]?.value)
        XCTAssertTrue(saved.isInjectOnly)
    }

    func test切换需要明确确认且取消保留草稿() throws {
        let (vm, _, _) = try fixture()
        vm.label = "My project"; vm.autoGenerateId()
        vm.fields[0].value = "synthetic-draft"
        XCTAssertFalse(vm.selectProvider("openai"))
        XCTAssertNil(vm.providerID)
        XCTAssertEqual(vm.fields[0].value, "synthetic-draft")
        XCTAssertTrue(vm.selectProvider("openai", discardValues: true))
        XCTAssertEqual(vm.label, "My project")
        XCTAssertEqual(vm.credentialId, "my-project")
        XCTAssertEqual(vm.fields[0].value, "")
    }

    func test所有必填字段与形状在写入之前校验() throws {
        let (vm, store, _) = try fixture()
        XCTAssertTrue(vm.selectProvider("apple-notary"))
        vm.fields[0].value = "synthetic-password"
        XCTAssertFalse(vm.isValid)
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try store.load().credentials.isEmpty)
        vm.fields[1].value = "synthetic@example.invalid"
        vm.fields[2].value = "TESTTEAM00"
        XCTAssertTrue(vm.isValid)
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        XCTAssertEqual(saved.fields["apple-id"]?.secret, false)
        XCTAssertEqual(saved.fields["apple-app-specific-password"]?.secret, true)

        vm.reset()
        let shaped = try XCTUnwrap(ProviderCatalog.all.first {
            $0.fields.count == 1 && !$0.prefixes.isEmpty && $0.primaryField.kind == .secretText
        })
        XCTAssertTrue(vm.selectProvider(shaped.id))
        vm.fields[0].value = "wrong-provider"
        XCTAssertFalse(vm.save())
        XCTAssertNil(try store.load().credentials[vm.credentialId])
    }

    func test禁止把模板密钥改为明文或偷换字段() throws {
        let (vm, store, _) = try fixture()
        XCTAssertTrue(vm.selectProvider("openai"))
        vm.fields[0].value = "sk-synthetic-test-only"
        vm.fields[0].isSecret = false
        XCTAssertFalse(vm.save())
        vm.fields[0].isSecret = true
        vm.fields[0].name = "other-key"
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try store.load().credentials.isEmpty)
    }

    func test本地签名身份不创建空壳或导出私钥() throws {
        let (vm, store, _) = try fixture()
        XCTAssertTrue(vm.selectProvider("developer-id"))
        XCTAssertNotNil(vm.providerProblem)
        XCTAssertFalse(vm.isValid)
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try store.load().credentials.isEmpty)
    }

    private func syntheticJSON() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        try Data(#"{"type":"service_account","client_email":"fixture@example.invalid","private_key":"synthetic-not-a-real-key"}"#.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test文件选择不读取内容保存时校验并保持文件字段() throws {
        let (vm, store, _) = try fixture()
        let template = try XCTUnwrap(ProviderCatalog.all.first {
            $0.fields.count == 1 && $0.primaryField.fileFormat == .serviceAccountJSON
        })
        XCTAssertTrue(vm.selectProvider(template.id))
        let url = try syntheticJSON()
        XCTAssertTrue(vm.setProviderFile(url, fieldName: template.fieldName))
        XCTAssertEqual(vm.fields[0].value, "", "文件内容不得进入表单或预览")
        XCTAssertFalse(vm.selectProvider("openai"))
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        XCTAssertEqual(saved.fields[template.fieldName]?.fileFormat, .serviceAccountJSON)
        XCTAssertNil(saved.fields[template.fieldName]?.value)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func test文件被替换或格式错误不写入任何字段() throws {
        let (vm, store, _) = try fixture()
        let template = try XCTUnwrap(ProviderCatalog.all.first {
            $0.fields.count == 1 && $0.primaryField.fileFormat == .serviceAccountJSON
        })
        XCTAssertTrue(vm.selectProvider(template.id))
        let url = try syntheticJSON()
        XCTAssertTrue(vm.setProviderFile(url, fieldName: template.fieldName))
        try Data("not a credential document".utf8).write(to: url, options: .atomic)
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try store.load().credentials.isEmpty)
        XCTAssertTrue(vm.setProviderFile(url, fieldName: template.fieldName), "选择只检查文件身份，不提前读值")
        XCTAssertFalse(vm.save())
        XCTAssertTrue(try store.load().credentials.isEmpty)
        vm.reset()
        XCTAssertNil(vm.providerID)
        XCTAssertFalse(vm.hasDraft)
        XCTAssertTrue(vm.providerFiles.isEmpty)
    }

    func test全目录字段类型及本地身份边界() throws {
        let (vm, _, _) = try fixture()
        for template in ProviderCatalog.all {
            vm.reset()
            XCTAssertTrue(vm.selectProvider(template.id), template.id)
            XCTAssertEqual(vm.fields.map(\.name), template.fields.map(\.name), template.id)
            XCTAssertEqual(vm.fields.map(\.isSecret), template.fields.map(\.isSaveableSecret), template.id)
            XCTAssertEqual(vm.fields.map(\.fileFormat), template.fields.map(\.fileFormat), template.id)
            XCTAssertFalse(vm.isValid, template.id)
            XCTAssertNil(vm.expires, "供应商有效期说明不能冒充实际到期日")
        }
    }

    func test新增模板中文文案与占位符一致() {
        for key in ["Provider template", "Required", "optional", "Change template?", "Clear values and change",
                    "Complete the required field: {0}", "Choose the required file: {0}",
                    "Template guidance", "Choose credential file…",
                    "Read only when you click Save. The original file is kept."] {
            let translated = AppL10n.render(key, language: "zh-Hans")
            XCTAssertNotEqual(translated, key)
            XCTAssertEqual(AppL10n.placeholders(in: key), AppL10n.placeholders(in: translated))
        }
    }

    func testP8和必填标识一起落盘而非半条凭据() throws {
        let (vm, store, session) = try fixture()
        XCTAssertTrue(vm.selectProvider("app-store-connect"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".p8")
        // Ephemeral test key only; never a production identity or provider-issued credential.
        let pem = P256.Signing.PrivateKey().pemRepresentation
        try Data(pem.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(vm.setProviderFile(url, fieldName: "private-key"))
        XCTAssertFalse(vm.save(), "尚缺 Key ID 和 Issuer ID")
        XCTAssertTrue(try store.load().credentials.isEmpty)
        vm.fields[1].value = "TESTKEY000"
        vm.fields[2].value = "00000000-0000-0000-0000-000000000001"
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        XCTAssertEqual(saved.fields.count, 3)
        XCTAssertEqual(saved.fields["private-key"]?.fileFormat, .applePrivateKeyP8)
        XCTAssertNil(saved.fields["private-key"]?.value)
        XCTAssertEqual(try session.retrieve(credentialId: vm.credentialId, fieldName: "private-key"), pem)
    }

    func test可选空字段不生成缺值空壳且取消模板恢复手动模式() throws {
        let (vm, store, _) = try fixture()
        let template = try XCTUnwrap(ProviderCatalog.all.first {
            $0.fields.contains(where: { !$0.required }) && $0.fields.allSatisfy { $0.kind == .secretText || $0.kind == .publicText }
        })
        XCTAssertTrue(vm.selectProvider(template.id))
        for i in vm.fields.indices where template.fields[i].required {
            // This template is selected for a metadata test; documented shapes remain authoritative.
            let field = template.fields[i]
            vm.fields[i].value = (field.prefixes.first ?? "") + String(repeating: "x", count: max(80, field.minChars ?? 0))
        }
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        for field in template.fields where !field.required { XCTAssertNil(saved.fields[field.name]) }
        vm.reset()
        XCTAssertTrue(vm.selectProvider("openai"))
        XCTAssertTrue(vm.selectProvider(""))
        XCTAssertNil(vm.providerID)
        XCTAssertEqual(vm.fields.first?.name, AddCredentialViewModel.defaultFieldName)
        XCTAssertFalse(vm.hasDraft)
    }
}
