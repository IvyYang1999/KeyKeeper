import XCTest
@testable import KeyKeeperCore

/// 【曾经的 bug · 独立审计 2026-09-13 定为 critical】身份改成取自连接的 audit token 之后，
/// 被认出来的是**直接连上 socket 的那个进程**——而几乎所有调用都经过 `keykeeper` 命令行
/// （两个 SDK 也都是转手调它）。于是所有调用方都塌缩成同一个指纹：KeyKeeper 自己的 CLI。
/// 给任何一个 Agent 的「始终允许」，就成了给本机所有经 CLI 调用的进程的「始终允许」。
///
/// 我们自己的、签过名的 CLI 是**信使**，不是调用方。真正的调用方是它上游的那个进程。
final class CourierIdentityTests: XCTestCase {
    private let ownCLIPath = "/Applications/KeyKeeper.app/Contents/MacOS/keykeeper"

    func test自家签名的CLI被认成信使() {
        XCTAssertTrue(CallerIdentityResolver.isOwnCLI(
            team: "ZPTA4LP594", signing: "keykeeper", executable: "/somewhere/else/keykeeper",
            ownTeam: "ZPTA4LP594", ownCLIPath: ownCLIPath))
        // 开发机上未签名的构建：按「就是我们包里那个文件」认
        XCTAssertTrue(CallerIdentityResolver.isOwnCLI(
            team: nil, signing: nil, executable: ownCLIPath,
            ownTeam: nil, ownCLIPath: ownCLIPath))
    }

    /// 别人签的、叫 keykeeper 的程序不能冒充信使——否则改个名字就能把身份洗掉。
    func test别人签的同名程序不算信使() {
        XCTAssertFalse(CallerIdentityResolver.isOwnCLI(
            team: "EVILTEAM00", signing: "keykeeper", executable: "/tmp/keykeeper",
            ownTeam: "ZPTA4LP594", ownCLIPath: ownCLIPath))
        XCTAssertFalse(CallerIdentityResolver.isOwnCLI(
            team: nil, signing: nil, executable: "/tmp/keykeeper",
            ownTeam: "ZPTA4LP594", ownCLIPath: ownCLIPath))
        XCTAssertFalse(CallerIdentityResolver.isOwnCLI(
            team: nil, signing: nil, executable: "/tmp/keykeeper",
            ownTeam: nil, ownCLIPath: ownCLIPath), "未签名的开发构建也只认包里那一个文件")
    }

    /// 上游进程找不到有用的身份时，退回的 `executable:pid=N` 不能成为可持有授权的身份。
    func test上游只剩pid时算未核实() {
        let upstream = CallerSubject(kind: .executable, fingerprint: "executable:pid=4242", displayName: "?", detail: "")
        let resolved = CallerIdentityResolver.courierUpstream(upstream)
        XCTAssertTrue(resolved.fingerprint.hasPrefix(CallerSubject.unverifiedPrefix), resolved.fingerprint)
        let app = CallerSubject(kind: .app, fingerprint: "app:team=unsigned:bundle=com.darkconstant.console:signing=Electron", displayName: "Console", detail: "")
        XCTAssertEqual(CallerIdentityResolver.courierUpstream(app).fingerprint, app.fingerprint,
                       "有身份的上游保持原样，已有授权才对得上")
    }
}
