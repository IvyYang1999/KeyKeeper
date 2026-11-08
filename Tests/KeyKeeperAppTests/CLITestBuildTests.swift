import XCTest
@testable import KeyKeeperApp

/// 【曾经的 bug】2026-11-08 主力 Mac 验收截图：测试版里写「CLI is out of date」并给「Update」，点了会把
/// 系统里的 keykeeper 链接改指向测试版。测试版不提示、不给按钮，安装器也拒绝。
@MainActor final class CLITestBuildTests: XCTestCase {
    func test曾经的Bug测试版不提示也不改已安装的命令行工具() {
        let original = CLIInstallState.leavesInstalledToolAlone
        defer { CLIInstallState.leavesInstalledToolAlone = original }

        CLIInstallState.leavesInstalledToolAlone = false
        XCTAssertTrue(CLIInstallState.stale(installed: "keykeeper old").needsAttention, "正式版照旧提示")
        XCTAssertNotNil(CLIInstallState.stale(installed: "keykeeper old").actionLabel)

        CLIInstallState.leavesInstalledToolAlone = true
        for state in [CLIInstallState.stale(installed: "keykeeper old"), .missing, .failed(path: "/usr/local/bin/keykeeper")] {
            XCTAssertFalse(state.needsAttention, "\(state)")
            XCTAssertNil(state.actionLabel, "\(state)")
            XCTAssertTrue(state.detail.contains("test build") || state.detail.contains("测试版"), state.detail)
        }
        XCTAssertNotNil(CLIInstaller.installWithAdminPrivileges(), "安装器在测试版里拒绝，不碰系统里的链接")
    }
}
