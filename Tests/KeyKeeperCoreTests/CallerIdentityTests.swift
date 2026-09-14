import XCTest
@testable import KeyKeeperCore

final class CallerIdentityTests: XCTestCase {
    func test_调用方身份优先使用父进程链里的App签名身份() {
        XCTContext.runActivity(named: "GUI 后代进程应归因到 App bundle，而不是 keykeeper CLI 自身") { _ in
            let chain = [
                CallerProcess(
                    pid: 100,
                    parentPID: 90,
                    executablePath: "/usr/local/bin/keykeeper"
                ),
                CallerProcess(
                    pid: 90,
                    parentPID: 80,
                    executablePath: "/bin/zsh"
                ),
                CallerProcess(
                    pid: 80,
                    parentPID: 1,
                    executablePath: "/Applications/Obsidian.app/Contents/MacOS/Obsidian",
                    bundleIdentifier: "md.obsidian",
                    teamIdentifier: "TEAM123",
                    signingIdentifier: "md.obsidian"
                ),
            ]

            let subject = CallerIdentityResolver.selectSubject(from: chain, peerPID: 100)

            XCTAssertEqual(subject.kind, .app)
            XCTAssertEqual(subject.displayName, "md.obsidian")
            XCTAssertEqual(subject.fingerprint, "app:team=TEAM123:bundle=md.obsidian:signing=md.obsidian")
        }
    }

    func test_无App父进程时使用脚本路径哈希作为服务主体() {
        XCTContext.runActivity(named: "cron/script 场景不能只授权 /bin/zsh，应归因到脚本路径哈希") { _ in
            let script = "/Users/example/bin/daily-job.sh"
            let chain = [
                CallerProcess(
                    pid: 100,
                    parentPID: 90,
                    executablePath: "/usr/local/bin/keykeeper"
                ),
                CallerProcess(
                    pid: 90,
                    parentPID: 1,
                    executablePath: "/bin/zsh",
                    scriptPath: script
                ),
            ]

            let subject = CallerIdentityResolver.selectSubject(from: chain, peerPID: 100)

            XCTAssertEqual(subject.kind, .script)
            XCTAssertEqual(subject.displayName, "daily-job.sh")
            XCTAssertEqual(
                subject.fingerprint,
                "script:sha256=\(CallerIdentityResolver.sha256Hex(script))"
            )
        }
    }

    func test_命令行工具有签名但无AppBundle时不当作App主体() {
        XCTContext.runActivity(named: "Apple 签名的 shell 不是 App bundle，不能抢占脚本主体") { _ in
            let script = "/Users/example/bin/daily-job.sh"
            let chain = [
                CallerProcess(
                    pid: 100,
                    parentPID: 90,
                    executablePath: "/usr/local/bin/keykeeper",
                    teamIdentifier: "TEAM",
                    signingIdentifier: "keykeeper"
                ),
                CallerProcess(
                    pid: 90,
                    parentPID: 1,
                    executablePath: "/bin/zsh",
                    teamIdentifier: "APPLE",
                    signingIdentifier: "com.apple.zsh",
                    scriptPath: script
                ),
            ]

            let subject = CallerIdentityResolver.selectSubject(from: chain, peerPID: 100)

            XCTAssertEqual(subject.kind, .script)
            XCTAssertEqual(subject.displayName, "daily-job.sh")
        }
    }
}

// MARK: - 2026-09-14 独立审计：未签名 App 的身份不能来自它自己盘上的 Info.plist

extension CallerIdentityTests {
    private func chain(appPath: String, bundle: String, team: String?) -> [CallerProcess] {
        [CallerProcess(pid: 100, parentPID: 80, executablePath: "/usr/local/bin/keykeeper"),
         CallerProcess(pid: 80, parentPID: 1, executablePath: appPath, bundleIdentifier: bundle,
                       teamIdentifier: team, signingIdentifier: bundle)]
    }

    /// 【独立审计 2026-09-14 · critical】未签名 App 的指纹以前是 `app:team=unsigned:bundle=<id>`，而 bundle id
    /// 是从进程祖先的 Info.plist 读出来的——任何进程造一个 Fake.app 写上 `com.openai.codex` 就等于 Codex，
    /// 吃到它的「始终允许」。现在没有可验证签名的 App 按可执行文件路径认（和未签名程序一样）。
    func test未签名App冒名同一个bundleId_指纹不同_不含bundleId() {
        let real = CallerIdentityResolver.selectSubject(from: chain(appPath: "/Applications/Codex.app/Contents/MacOS/Codex", bundle: "com.openai.codex", team: nil), peerPID: 100)
        let fake = CallerIdentityResolver.selectSubject(from: chain(appPath: "/Users/x/evil/Fake.app/Contents/MacOS/x", bundle: "com.openai.codex", team: nil), peerPID: 100)
        XCTAssertNotEqual(real.fingerprint, fake.fingerprint)
        XCTAssertFalse(real.fingerprint.contains("com.openai.codex"), real.fingerprint)
        XCTAssertTrue(real.fingerprint.hasPrefix("app:unsigned:path="), real.fingerprint)
        XCTAssertEqual(real.displayName, "com.openai.codex", "名字照样显示，只是不拿它当身份")
        XCTAssertEqual(real.kind, .app)
        // 同一个 App 再来还是它。
        XCTAssertEqual(real.fingerprint, CallerIdentityResolver.selectSubject(from: chain(appPath: "/Applications/Codex.app/Contents/MacOS/Codex", bundle: "com.openai.codex", team: nil), peerPID: 100).fingerprint)
        XCTAssertEqual(CallerAssurance_tierWord(real.fingerprint), "unsigned")
    }

    func test有签名的App仍按团队认() {
        let signed = CallerIdentityResolver.selectSubject(from: chain(appPath: "/Applications/Obsidian.app/Contents/MacOS/Obsidian", bundle: "md.obsidian", team: "TEAM123"), peerPID: 100)
        XCTAssertEqual(signed.fingerprint, "app:team=TEAM123:bundle=md.obsidian:signing=md.obsidian")
    }

    func test未签名App找不到可执行路径_不能持有授权() {
        let chain = [CallerProcess(pid: 100, parentPID: 80, executablePath: "/usr/local/bin/keykeeper"),
                     CallerProcess(pid: 80, parentPID: 1, executablePath: nil, bundleIdentifier: "com.openai.codex")]
        let subject = CallerIdentityResolver.selectSubject(from: chain, peerPID: 100)
        XCTAssertTrue(subject.fingerprint.hasPrefix(CallerSubject.unverifiedPrefix), subject.fingerprint)
    }

    /// The tier word the app derives, mirrored here so Core tests can pin it without importing the app.
    private func CallerAssurance_tierWord(_ fingerprint: String) -> String {
        if fingerprint.hasPrefix("app:team="), !fingerprint.hasPrefix("app:team=unsigned:") { return "signed" }
        if fingerprint.hasPrefix(CallerSubject.unverifiedPrefix) { return "unverified" }
        return "unsigned"
    }
}
