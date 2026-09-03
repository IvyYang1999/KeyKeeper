import Foundation
import XCTest
@testable import KeyKeeperApp

final class CLIInstallStateTests: XCTestCase {
    /// 【曾经的 bug】Setup 只查文件存在，4 个月旧的 CLI 也显示「已安装」（07-10 部署错位）。
    func test曾经的Bug旧版本CLI判为stale而不是完成() {
        XCTAssertEqual(
            CLIInstallState.derive(installedVersion: "keykeeper 0000000aaaaa", appVersion: "keykeeper 111111bbbbbb"),
            .stale(installed: "keykeeper 0000000aaaaa")
        )
        XCTAssertEqual(
            CLIInstallState.derive(installedVersion: "keykeeper 111111bbbbbb", appVersion: "keykeeper 111111bbbbbb"),
            .current(installed: "keykeeper 111111bbbbbb")
        )
        XCTAssertEqual(CLIInstallState.derive(installedVersion: nil, appVersion: "keykeeper 1"), .missing)
        XCTAssertEqual(CLIInstallState.derive(installedVersion: "", appVersion: "keykeeper 1"), .missing)
    }

    func test无git元数据的构建不判stale() {
        XCTAssertTrue(
            CLIInstallState.derive(installedVersion: "keykeeper abc", appVersion: "keykeeper unknown").isCurrent
        )
    }

    func test探测不到二进制时为missing() {
        XCTAssertEqual(
            CLIInstallState.probe(appVersion: "keykeeper x", paths: ["/nonexistent/keykeeper"]),
            .missing
        )
    }

    func test技能文件两种位置都算已安装() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-skill-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertFalse(CLIInstallState.skillInstalled(home: home))

        let dir = home.appendingPathComponent(".claude/skills/keykeeper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("---\n".utf8).write(to: dir.appendingPathComponent("SKILL.md"))
        XCTAssertTrue(CLIInstallState.skillInstalled(home: home))
    }
}
