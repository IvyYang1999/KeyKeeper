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

/// 【曾经的 bug】yyt 的机器上 `/usr/local/bin` 根本不存在，`keykeeper` 在
/// `/opt/homebrew/bin`——而安装器把目标写死成 `/usr/local/bin/keykeeper`。于是点「更新」
/// 是往一个**不在 PATH 上的地方**装一份新的，shell 里跑的还是那个旧的，看起来像是没反应。
final class CLIInstallTargetTests: XCTestCase {
    private func target(existing: [String], writable: Set<String>) -> CLIInstaller.Target {
        CLIInstaller.preferredTarget(
            existing: { existing.contains($0) },
            writableDirectory: { writable.contains($0) })
    }

    func test已经装过的就装回同一个地方() {
        let homebrew = target(existing: ["/opt/homebrew/bin/keykeeper"], writable: ["/opt/homebrew/bin"])
        XCTAssertEqual(homebrew.path, "/opt/homebrew/bin/keykeeper")
        XCTAssertFalse(homebrew.needsAdmin, "目录本来就能写，不该再要一次管理员密码")
    }

    func test目录能写就不要管理员密码() {
        XCTAssertFalse(target(existing: [], writable: ["/opt/homebrew/bin"]).needsAdmin)
    }

    /// 两个地方都有的时候，PATH 上排在前面的那个才是真正会被跑到的。
    func test两处都有时选PATH靠前的那个() {
        let both = target(existing: ["/usr/local/bin/keykeeper", "/opt/homebrew/bin/keykeeper"],
                          writable: ["/opt/homebrew/bin", "/usr/local/bin"])
        XCTAssertEqual(both.path, CLIInstallState.searchPaths.first)
    }

    /// 全新的 Mac：哪儿都没有、哪儿都不能写，那就回到 /usr/local/bin 并要一次密码。
    func test都没有时回到系统目录并要密码() {
        let fresh = target(existing: [], writable: [])
        XCTAssertEqual(fresh.path, "/usr/local/bin/keykeeper")
        XCTAssertTrue(fresh.needsAdmin)
    }
}
