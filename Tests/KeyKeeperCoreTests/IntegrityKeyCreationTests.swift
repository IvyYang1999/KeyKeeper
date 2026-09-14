import XCTest
import Security
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 照真实钥匙串的写入语义来：「替换」只更新，条目不在就报错；「新建」只新增，条目已在就报错。

/// 【独立审计 2026-09-13 · critical】完整性密钥用「替换」模式写入，而真实钥匙串的替换只做更新——条目还不存在
/// 就直接报错。于是密钥从来没建出来：App 写授权文件全部失败（批准存不下、撤销做不了），meta.json 也从没签过名。
/// 之前的测试替身不理会这个参数，所以一直是绿的。
final class IntegrityKeyCreationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("integrity-key-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test第一次能在真实语义下建出密钥() throws {
        let io = FakeKeychainIO()
        let key = try MetaIntegrityKey.loadOrCreate(io: io)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try MetaIntegrityKey.loadOrCreate(io: io), key, "第二次读回同一把")
    }

    func test授权文件在真实语义下能写并签上名() throws {
        let store = GrantStore(directory: dir, integrity: GrantFileIntegrity(io: FakeKeychainIO()))
        XCTAssertNoThrow(try store.addGrant(Grant(credentialId: "c", duration: .always, subjectFingerprint: "unsigned:path=a")))
        let text = try String(contentsOf: dir.appendingPathComponent("grants.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\"integrity\""))
    }

    func test元数据在真实语义下签得上名() throws {
        let store = MetaStore(directory: dir, integrityIO: FakeKeychainIO())
        try store.save(MetaFile())
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
    }
}
