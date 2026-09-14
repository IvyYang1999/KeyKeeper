import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 【独立审计 2026-09-13 · critical】完整性密钥用「替换」模式写入，而真实钥匙串的替换只做更新——条目还不存在
/// 就直接报错。于是密钥从来没建出来，meta.json 从没签过名。之前的测试替身不理会这个参数，所以一直是绿的。
final class IntegrityKeyCreationTests: XCTestCase {
    func test第一次能在真实语义下建出密钥() throws {
        let io = FakeKeychainIO()
        let key = try MetaIntegrityKey.loadOrCreate(io: io)
        XCTAssertEqual(key.count, 32)
        XCTAssertEqual(try MetaIntegrityKey.loadOrCreate(io: io), key, "第二次读回同一把")
    }

    func test元数据在真实语义下签得上名() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("integrity-key-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MetaStore(directory: dir, integrityIO: FakeKeychainIO())
        try store.save(MetaFile())
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
    }
}
