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

/// yyt 2026-09-13：「这个命令行工具，不是应该和版本一起更新嘛，这个谁能发现得了这个更新入口。」
///
/// 原来安装是把 App 里的二进制**复制**到 /usr/local/bin，于是每次 App 升级，那份复制品
/// 就落后一个版本，而唯一的补救入口埋在设置页里，还要再输一次管理员密码。改成软链接：
/// 指向 App 包里的那个二进制，App 一升级它自动跟着走，此生只需授权一次。
final class CLIInstallScriptTests: XCTestCase {
    private let bundle = "/Applications/KeyKeeper.app/Contents/MacOS/keykeeper"

    func test装的是软链接而不是复制品() {
        let script = CLIInstaller.installScript(bundleCLI: bundle, target: "/usr/local/bin/keykeeper")
        XCTAssertTrue(script.contains("ln -sfn"), script)
        XCTAssertFalse(script.contains("cp "), "复制出来的那份不会跟着 App 升级：\(script)")
        XCTAssertTrue(script.contains("mkdir -p /usr/local/bin"), "全新的 Mac 上这个目录可能不存在")
    }

    /// 路径里带引号也不能把脚本拼坏——这段是拿管理员权限跑的，所以真跑一遍看它做了什么。
    func test带引号的路径不会变成可执行的命令() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-install-\(UUID())")
        let odd = root.appendingPathComponent("Key'name.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fake = odd.appendingPathComponent("keykeeper")
        try Data("#!/bin/sh\necho fake\n".utf8).write(to: fake)
        let canary = root.appendingPathComponent("canary")
        try Data("still here".utf8).write(to: canary)

        // 一个企图借路径逃出引号的名字
        let hostile = fake.path + "'; rm -f '\(canary.path)'; echo '"
        let target = root.appendingPathComponent("bin/keykeeper")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", CLIInstaller.installScript(bundleCLI: hostile, target: target.path)]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        XCTAssertTrue(FileManager.default.fileExists(atPath: canary.path),
                      "路径里的内容被当成命令执行了")
        let link = try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)
        XCTAssertEqual(link, hostile, "整个路径应该原样成为软链接目标，而不是被拆开")
    }

    func test真的装出一个跟着App走的软链接() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-install-\(UUID())")
        let macos = root.appendingPathComponent("KeyKeeper.app/Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = macos.appendingPathComponent("keykeeper")
        try Data("#!/bin/sh\necho v1\n".utf8).write(to: binary)
        let target = root.appendingPathComponent("bin/keykeeper")
        // 先放一份老版本留下的复制品，新装法必须能把它换掉
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\necho stale\n".utf8).write(to: target)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", CLIInstaller.installScript(bundleCLI: binary.path, target: target.path)]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.path), binary.path)

        // App 升级 = 包里的二进制被换掉，软链接那头什么都不用做
        try Data("#!/bin/sh\necho v2\n".utf8).write(to: binary)
        XCTAssertEqual(String(decoding: try Data(contentsOf: target), as: UTF8.self), "#!/bin/sh\necho v2\n")
    }

    /// 软链接跟着 App 走，所以「装过了但落后了」这个状态在新装法下不该出现。
    func test软链接下版本天然一致() {
        XCTAssertEqual(CLIInstallState.derive(installedVersion: "abc123", appVersion: "abc123"),
                       .current(installed: "abc123"))
    }
}
