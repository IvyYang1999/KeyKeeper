import XCTest
@testable import KeyKeeperCore

/// 不弹窗，但每次改动都留一笔，用户在访问记录里能看到是谁改了什么。
final class MetadataChangeLogTests: XCTestCase {
    func test记录改动并只保留最近两百条() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kk-changes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = MetadataChangeLog(directory: directory)
        XCTAssertEqual(try log.records(), [])
        for index in 0..<205 {
            try log.append(MetadataChangeRecord(caller: "claude", groupId: "g\(index)", label: "G",
                                                changes: [.notesChanged], timestamp: Date(timeIntervalSince1970: TimeInterval(index))))
        }
        let records = try log.records()
        XCTAssertEqual(records.count, 200)
        XCTAssertEqual(records.first?.groupId, "g5")
        XCTAssertEqual(records.last?.changes, [.notesChanged])
    }
}
