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
