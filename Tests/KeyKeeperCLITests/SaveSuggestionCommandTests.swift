import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class SaveSuggestionCommandTests: XCTestCase {
    func test保存命令带上建议() throws {
        let command = try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create",
                                             "--security", "standard", "--expires", "2026-12-31",
                                             "--purpose", "nightly backup", "--frequency", "scheduled", "--background",
                                             "--expected-caller", "cron"])
        XCTAssertEqual(command.request.security, .standard)
        XCTAssertEqual(command.request.expires, "2026-12-31")
        XCTAssertEqual(command.request.intent, UsageIntent(purpose: "nightly backup", expectedCaller: "cron", frequency: .scheduled, background: true))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--security", "standard", "--purpose", "p"]),
                             "不是新建就没有建议可言")
    }

    /// yyt 2026-09-14：Agent 建议后台运行时，必须说清用途，后面的请求都拿它来对照。
    func test后台保护必须声明用途_描述性参数必须跟着用途() throws {
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create", "--security", "standard"])) { error in
            XCTAssertTrue(SaveCommand.fullMessage(for: error).contains("--purpose"))
        }
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create", "--background"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create", "--frequency", "weekly", "--purpose", "p"]), "频率只认三档")
        let strict = try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create"])
        XCTAssertNil(strict.request.intent, "strict 不强求声明")
        let blank = try SaveCommand.parse(["-c", "x", "--field", "k", "--from-clipboard", "--create", "--purpose", " \u{200B} "])
        XCTAssertNil(blank.request.intent, "空白用途等于没写")
    }

    func test读取命令接受时长愿望() throws {
        XCTAssertEqual(try RunCommand.parse(["-c", "x", "--duration", "1h", "--", "echo"]).duration, .oneHour)
        XCTAssertEqual(try GetCommand.parse(["x", "f", "--duration", "always"]).duration, .always)
        XCTAssertThrowsError(try GetCommand.parse(["x", "f", "--duration", "forever"]))
        XCTAssertEqual(RunCommand.commandSummary(["vercel", "deploy\u{200B}", "--prod"]), "vercel deploy --prod")
        XCTAssertEqual(RunCommand.commandSummary([String](repeating: "x", count: 300))?.count, 200)
        XCTAssertNil(RunCommand.commandSummary([]))
    }
}

extension SaveSuggestionCommandTests {
    /// `get` 在问 App 之前就拒绝只注入的凭据，告诉 Agent 用 `run`、告诉人在 App 里能改。
    func testGet对只注入的凭据直接拒绝() {
        let cred = Credential(label: "Stripe", notes: "", links: [], fields: ["k": .init(secret: true)], security: .strict,
                              created: "", updated: "", injectOnly: true)
        let message = GetCommand.injectOnlyRefusal(credentialId: "stripe", credential: cred)!
        XCTAssertTrue(message.contains("keykeeper run -c stripe") && message.contains("KeyKeeper"), message)
        var open = cred; open.injectOnly = false
        XCTAssertNil(GetCommand.injectOnlyRefusal(credentialId: "stripe", credential: open))
    }
}
