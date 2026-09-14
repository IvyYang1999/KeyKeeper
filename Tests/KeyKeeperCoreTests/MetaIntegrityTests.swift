import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 【安全审计 2026-09-13】meta.json 是明文，而它决定**哪些字段是机密**、每条凭据的安全
/// 级别，还直接存着明文字段的值。同 UID 进程改一行就能：把 `secret: true` 翻成 false 再
/// 填一个自选的值，于是 `keykeeper get` 不读钥匙串、不查授权、不留审计，直接把攻击者写
/// 的东西交给 Agent（比如把某个 API 地址换成他自己的）。程序化自检也查不出来。
///
/// 这一层给 meta.json 加一个 HMAC，密钥放在钥匙串里（和凭据同一种保护）。
final class MetaIntegrityTests: XCTestCase {
    private let key = Data(repeating: 0x5A, count: 32)

    private func meta() -> MetaFile {
        MetaFile(credentials: [
            "openai": Credential(label: "OpenAI", notes: "", links: [],
                                 fields: ["api-key": CredentialField(secret: true)],
                                 security: .strict, created: "2026-09-13", updated: "2026-09-13")
        ])
    }

    func test同样的内容算出同样的印记() throws {
        let a = try MetaIntegrity.mac(for: meta(), key: key)
        let b = try MetaIntegrity.mac(for: meta(), key: key)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    /// 改动任何一处都要算出不同的印记——尤其是这三处，它们直接决定取值走哪条路。
    func test改动机密标志安全级别或明文值都会变() throws {
        let original = try MetaIntegrity.mac(for: meta(), key: key)

        var flipped = meta()
        flipped.credentials["openai"]?.fields["api-key"]?.secret = false
        XCTAssertNotEqual(try MetaIntegrity.mac(for: flipped, key: key), original)

        var downgraded = meta()
        downgraded.credentials["openai"]?.security = .standard
        XCTAssertNotEqual(try MetaIntegrity.mac(for: downgraded, key: key), original)

        var injected = meta()
        injected.credentials["openai"]?.fields["api-key"]?.value = "https://attacker.invalid"
        XCTAssertNotEqual(try MetaIntegrity.mac(for: injected, key: key), original)
    }

    /// 印记本身不参与计算，否则写进去之后就永远对不上了。
    func test印记字段不参与计算() throws {
        var withMac = meta()
        withMac.integrity = "whatever"
        XCTAssertEqual(try MetaIntegrity.mac(for: withMac, key: key),
                       try MetaIntegrity.mac(for: meta(), key: key))
    }

    func test换一把密钥就对不上() throws {
        XCTAssertNotEqual(try MetaIntegrity.mac(for: meta(), key: Data(repeating: 0x11, count: 32)),
                          try MetaIntegrity.mac(for: meta(), key: key))
    }

    func test校验能分辨三种情况() throws {
        var signed = meta()
        signed.integrity = try MetaIntegrity.mac(for: signed, key: key)
        XCTAssertEqual(MetaIntegrity.verify(signed, key: key), .intact)

        var tampered = signed
        tampered.credentials["openai"]?.fields["api-key"]?.secret = false
        XCTAssertEqual(MetaIntegrity.verify(tampered, key: key), .tampered)

        // 0.3.3 写的文件没有这个字段
        XCTAssertEqual(MetaIntegrity.verify(meta(), key: key), .unsigned)
    }
}

/// 存储层：印记什么时候写、什么时候认、什么时候翻脸。
final class MetaStoreIntegrityTests: XCTestCase {
    private func store() -> (MetaStore, FakeKeychainIO, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-integrity-\(UUID())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let io = FakeKeychainIO()
        return (MetaStore(directory: dir, integrityIO: io), io, dir)
    }
    private func meta() -> MetaFile {
        MetaFile(credentials: [
            "openai": Credential(label: "OpenAI", notes: "", links: [],
                                 fields: ["api-key": CredentialField(secret: true)],
                                 security: .strict, created: "2026-09-13", updated: "2026-09-13")
        ])
    }

    func test保存时写印记读取时认得出来() throws {
        let (store, _, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(meta())
        let loaded = try store.loadVerified()
        XCTAssertEqual(loaded.verdict, .intact)
        XCTAssertNotNil(loaded.meta.integrity)
    }

    /// 有人改了文件——`secret: true` 翻成 false 并塞了个值。
    func test改过的文件会被认出来() throws {
        let (store, _, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(meta())

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var credentials = try XCTUnwrap(object["credentials"] as? [String: Any])
        var openai = try XCTUnwrap(credentials["openai"] as? [String: Any])
        var fields = try XCTUnwrap(openai["fields"] as? [String: Any])
        fields["api-key"] = ["secret": false, "value": "https://attacker.invalid"]
        openai["fields"] = fields; credentials["openai"] = openai; object["credentials"] = credentials
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        XCTAssertEqual(try store.loadVerified().verdict, .tampered)
    }

    /// 【关键】把印记整行删掉，不能因此被当成「老文件」放过去——否则这道防线一删就没了。
    /// 判据是钥匙串里有没有那把密钥：有，就说明这台机器早就开始签了。
    func test删掉印记等于篡改而不是老文件() throws {
        let (store, _, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.save(meta())

        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: store.fileURL)) as? [String: Any])
        object.removeValue(forKey: "integrity")
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)

        XCTAssertEqual(try store.loadVerified().verdict, .tampered)
    }

    /// 0.3.3 写的文件 + 还没生成过密钥 = 老文件，照常读，下次保存时补上印记。
    func test真正的老文件被接纳并在下次保存时补签() throws {
        let (store, io, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta()).write(to: store.fileURL)
        XCTAssertNil(io.blob, "还没有密钥")

        XCTAssertEqual(try store.loadVerified().verdict, .unsigned)
        try store.save(try store.load())
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
    }

    /// 没有密钥可用时（钥匙串读不到），不能假装一切正常。
    func test钥匙串读不到时不谎报完好() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meta-integrity-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let io = FakeKeychainIO(); io.failReads = true
        let store = MetaStore(directory: dir, integrityIO: io)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta()).write(to: store.fileURL)
        XCTAssertEqual(try store.loadVerified().verdict, .unsigned)
    }
}

