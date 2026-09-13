import XCTest
import Darwin
@testable import KeyKeeperCore

/// 【独立审计 2026-09-13】授权文件的锁还有两处遗留：
/// 1. ServiceGrantStore 在拿锁**之前**先建空数据文件——正是 GrantStore 删掉的那个竞态：另一个
///    写者在锁里刚写进的授权会被这份空文件整个盖掉，enforced 还会退回 permissive。
/// 2. 锁文件用 open(O_CREAT) 打开，没有 O_NOFOLLOW：有人把 .lock 换成指向别处的符号链接，
///    我们就替他在那里建了文件。
final class GrantFileLockTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grant-lock-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testService授权不在锁外建数据文件() throws {
        let holder = open(dir.appendingPathComponent("service-grants.json.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        let store = ServiceGrantStore(directory: dir)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.addGrant(ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=abc",
                                             subjectDisplayName: "x", fields: ["f"], duration: .always))
            done.signal()
        }
        // 写者此刻卡在锁上。锁外什么都不该发生。
        XCTAssertEqual(done.wait(timeout: .now() + 0.3), .timedOut)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("service-grants.json").path),
                       "拿到锁之前就建了数据文件")
        flock(holder, LOCK_UN); close(holder)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertNotNil(try store.findValidGrant(credentialId: "c", subjectFingerprint: "unsigned:path=abc", fieldName: "f"))
    }

    func testService锁文件不跟随符号链接() throws {
        let victim = dir.appendingPathComponent("victim")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("service-grants.json.lock"),
                                                   withDestinationURL: victim)
        let store = ServiceGrantStore(directory: dir)
        XCTAssertThrowsError(try store.addGrant(ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=abc",
                                                             subjectDisplayName: "x", fields: ["f"], duration: .always)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path), "顺着符号链接在别处建了文件")
    }
}

extension GrantFileLockTests {
    func test授权锁文件不跟随符号链接() throws {
        let victim = dir.appendingPathComponent("victim-grants")
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("grants.json.lock"),
                                                   withDestinationURL: victim)
        let store = GrantStore(directory: dir)
        XCTAssertThrowsError(try store.addGrant(Grant(credentialId: "c", duration: .always,
                                                      subjectFingerprint: "unsigned:path=abc")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path), "顺着符号链接在别处建了文件")
    }
}
