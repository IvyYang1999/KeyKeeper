import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

/// Synthetic .env files in a temp directory, an in-memory Keychain, a fake prompt. No real store.
@MainActor final class EnvImportControllerTests: XCTestCase {
    private var dir: URL!
    private var service: KeychainCredentialService!
    private var metaStore: MetaStore!
    private var keychainIO: FakeKeychainIO!
    private var presented: [EnvImportController.Presentation] = []
    private var decide: ((Bool) -> Void)?

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kk-env-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keychainIO = FakeKeychainIO()
        service = KeychainCredentialService(store: KeychainBlobStore(io: keychainIO))
        metaStore = MetaStore(directory: dir)
        try metaStore.save(MetaFile(version: 1, credentials: [:]))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func controller(now: @escaping () -> Date = Date.init) -> EnvImportController {
        EnvImportController(service: service, metaStore: metaStore, approvals: .inMemory(), now: now,
            present: { [weak self] info, decide in self?.presented.append(info); self?.decide = decide },
            dismiss: {})
    }

    private func writeEnv(_ text: String, name: String = ".env") throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    func test批准后所有值进钥匙串元数据无值且只注入() throws {
        let path = try writeEnv("""
        OPENAI_API_KEY=sk-synthetic-1234567890abcdef
        DATABASE_URL="postgres://u:p@db.example/app"
        PORT=3000
        EMPTY=
        """)
        let sut = controller()
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "my-app", filePath: path, label: "My App"), callerName: "codex",
                    isConnected: { true }) { response = $0 }
        XCTAssertEqual(presented.count, 1)
        XCTAssertEqual(presented.first?.plan.secretNames, ["OPENAI_API_KEY", "DATABASE_URL", "PORT"])
        XCTAssertEqual(presented.first?.plan.plainNames, [])
        XCTAssertEqual(presented.first?.plan.skipped.map(\.name), ["EMPTY"])
        XCTAssertNil(response, "弹窗之前什么都不写")
        decide?(true)
        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(response?.detail, "3 secret, 0 plain, 1 skipped")
        XCTAssertEqual(try service.retrieve(credentialId: "my-app", fieldName: "openai-api-key"), "sk-synthetic-1234567890abcdef")
        XCTAssertEqual(try service.retrieve(credentialId: "my-app", fieldName: "database-url"), "postgres://u:p@db.example/app")
        let saved = try XCTUnwrap(try metaStore.load().credentials["my-app"])
        XCTAssertEqual(saved.label, "My App")
        XCTAssertNil(saved.fields["port"]?.value)
        XCTAssertEqual(saved.fields["port"]?.secret, true)
        XCTAssertEqual(try service.retrieve(credentialId: "my-app", fieldName: "port"), "3000")
        XCTAssertTrue(saved.fields.values.allSatisfy { $0.secret && $0.value == nil })
        XCTAssertNil(saved.fields["port"]?.setByCaller, "人在窗口里批准过，不需要再确认")
        XCTAssertEqual(saved.fields["openai-api-key"]?.secret, true)
        XCTAssertNil(saved.fields["openai-api-key"]?.value)
        XCTAssertEqual(saved.isInjectOnly, true)
        XCTAssertEqual(saved.security, .strict)
        XCTAssertFalse(sut.isPending)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "原文件不动")
    }

    func test拒绝不写任何东西() throws {
        let path = try writeEnv("API_KEY=sk-synthetic-000000000000")
        let sut = controller()
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "codex", isConnected: { true }) { response = $0 }
        decide?(false)
        XCTAssertEqual(response?.errorCode, .denied)
        XCTAssertNil(try metaStore.load().credentials["app"])
        XCTAssertNil(try service.fieldNamesByCredential()["app"])
    }

    // 【曾经的 bug】校验失败后不能留下已经提交但值又被清掉的元数据。
    func test写后校验失败不会留下缺值凭据() throws {
        let path = try writeEnv("VALUE=synthetic")
        keychainIO.afterWrite = { [keychainIO] in
            keychainIO!.afterWrite = nil
            keychainIO!.keychain.failNextReads(of: keychainIO!.service, count: 1)
        }
        let sut = controller()
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "codex", isConnected: { true }) { response = $0 }
        decide?(true)
        XCTAssertEqual(response?.success, false)
        XCTAssertNil(try metaStore.load().credentials["app"])
        XCTAssertNil(try service.fieldNamesByCredential()["app"])
    }

    func test格式不完整整份拒绝且不写入() throws {
        let path = try writeEnv("FIRST=synthetic\nSECOND=\"unfinished")
        let sut = controller()
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "codex", isConnected: { true }) { response = $0 }
        XCTAssertEqual(response?.errorCode, .invalidEnvFile)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertNil(try metaStore.load().credentials["app"])
        XCTAssertNil(try service.fieldNamesByCredential()["app"])
    }

    func test窗口开着时文件被改就拒绝且不留孤儿值() throws {
        let path = try writeEnv("API_KEY=sk-synthetic-000000000000\nOTHER_TOKEN=tok-synthetic-11111111111")
        let sut = controller()
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "codex", isConnected: { true }) { response = $0 }
        sleep(1)  // mtime granularity
        try "API_KEY=sk-synthetic-000000000000\nOTHER_TOKEN=tok-synthetic-11111111111\nEXTRA_KEY=sk-added-000000000000".write(toFile: path, atomically: true, encoding: .utf8)
        decide?(true)
        XCTAssertEqual(response?.errorCode, .fileChanged)
        XCTAssertNil(try metaStore.load().credentials["app"])
        XCTAssertNil(try service.fieldNamesByCredential()["app"])
    }

    func test已有ID孤儿值和非env文件都在弹窗前拒绝() throws {
        let path = try writeEnv("API_KEY=sk-synthetic-000000000000")
        var meta = try metaStore.load()
        meta.credentials["taken"] = Credential(label: "t", notes: "", links: [], fields: [:], security: .strict, created: "2026", updated: "2026")
        try metaStore.save(meta)
        try service.saveMissing(credentialId: "orphan", fieldName: "x", value: "y")
        let sut = controller()
        var codes: [ClipboardSaveError?] = []
        sut.receive(.init(credentialId: "taken", filePath: path), callerName: "c", isConnected: { true }) { codes.append($0.errorCode) }
        sut.receive(.init(credentialId: "orphan", filePath: path), callerName: "c", isConnected: { true }) { codes.append($0.errorCode) }
        let py = try writeEnv("X=1", name: "config.py")
        sut.receive(.init(credentialId: "fresh", filePath: py), callerName: "c", isConnected: { true }) { codes.append($0.errorCode) }
        let empty = try writeEnv("# nothing\nlower=1\n", name: ".env.empty")
        sut.receive(.init(credentialId: "fresh", filePath: empty), callerName: "c", isConnected: { true }) { codes.append($0.errorCode) }
        XCTAssertEqual(codes, [.credentialExists, .credentialExists, .invalidEnvFile, .emptyEnvFile])
        XCTAssertTrue(presented.isEmpty)
    }

    func test过期后不再能批准() throws {
        let path = try writeEnv("API_KEY=sk-synthetic-000000000000")
        var clock = Date()
        let sut = controller(now: { clock })
        var response: ClipboardSaveResponse?
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "c", isConnected: { true }) { response = $0 }
        clock = clock.addingTimeInterval(91)
        decide?(true)
        XCTAssertEqual(response?.errorCode, .expired)
        XCTAssertNil(try service.fieldNamesByCredential()["app"])
    }

    func test弹窗文案列出变量名且有中文() throws {
        let path = try writeEnv("API_KEY=sk-synthetic-000000000000\nPORT=1")
        let sut = controller()
        sut.receive(.init(credentialId: "app", filePath: path), callerName: "codex", isConnected: { true }) { _ in }
        let model = TrustPromptModel.envImport(try XCTUnwrap(presented.first))
        XCTAssertTrue(model.rows.contains { $0.label == L("Secrets") && $0.value == "API_KEY  PORT" })
        XCTAssertFalse(model.rows.contains { $0.label == L("Plain") })
        XCTAssertFalse(model.rows.contains { $0.value.contains("sk-synthetic") }, "值不进窗口")
        for key in ["Move this .env into KeyKeeper?", "Secrets", "Plain", "Skipped", "Import", "New, {0} fields",
                    "{0} wants its secrets out of the plaintext file",
                    "{0} never sees the values. The file is left where it is; delete it yourself once everything runs."] {
            let zh = AppL10n.render(key, language: "zh-Hans")
            XCTAssertNotEqual(zh, key, key)
            XCTAssertEqual(AppL10n.placeholders(in: key), AppL10n.placeholders(in: zh))
        }
    }
}
