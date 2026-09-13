import XCTest
@testable import KeyKeeperCore

/// 【安全审计 2026-09-13】两个 grant store 的 flock 都被 `.atomic` 写架空了：锁加在打开的
/// 那个 inode 上，而 `Data.write(options: .atomic)` 写完临时文件后 rename 覆盖，换掉的是
/// inode。于是后来者按路径打开拿到的是**新的** inode，它的 flock 立刻成功——两个写者同时
/// 进入临界区，后写的那次把前一次整份覆盖掉。
///
/// 影响的是「撤销授权」「消费一次性授权」「切换 enforced 模式」这类写入：可能被静默丢弃，
/// 也就是撤销之后授权还在。
final class GrantStoreConcurrencyTests: XCTestCase {
    func test并发写入一条都不能丢() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)
        let count = 40

        DispatchQueue.concurrentPerform(iterations: count) { index in
            try? store.addGrant(.init(credentialId: "c\(index)", duration: .always,
                                      subjectFingerprint: "fp", subjectDisplayName: "Agent"))
        }

        let written = try (0..<count).filter { try !store.grants(for: "c\($0)").isEmpty }.count
        XCTAssertEqual(written, count, "\(count - written) 次写入被另一个写者盖掉了")
    }

    func test并发撤销之后真的撤销了() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("concurrency-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GrantStore(directory: dir)
        let grants = (0..<30).map {
            Grant(credentialId: "c\($0)", duration: .always,
                  subjectFingerprint: "fp", subjectDisplayName: "Agent")
        }
        for grant in grants { try store.addGrant(grant) }

        DispatchQueue.concurrentPerform(iterations: grants.count) { index in
            try? store.revokeGrant(id: grants[index].id)
        }

        let left = try (0..<grants.count).filter { try !store.grants(for: "c\($0)").isEmpty }
        XCTAssertEqual(left, [], "撤销被丢了：\(left.count) 条授权还在")
    }
}
