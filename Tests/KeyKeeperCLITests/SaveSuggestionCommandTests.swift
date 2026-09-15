import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class SaveSuggestionCommandTests: XCTestCase {
    func test旧智谱Provider拼写保留原保存目标而新ID使用新字段() throws {
        for (spelling, oldID, oldField) in [
            ("zhipu", "zhipu", "zhipuai-api-key"), ("glm", "zhipu", "zhipuai-api-key"),
            ("zhipu-coding", "zhipu-coding", "zai-api-key"),
            ("zai", "zai", "zai-api-key"), ("zai-coding", "zai-coding", "zai-api-key"),
        ] {
            let command = try SaveCommand.parse(["--provider", spelling, "--from-clipboard", "--replace", "--expect", "chars:40"])
            XCTAssertEqual(command.credentialId, oldID)
            XCTAssertEqual(command.fieldName, oldField)
            XCTAssertEqual(command.remainingFieldsNote, "")
        }
        let fresh = try SaveCommand.parse(["--provider", "zhipu-cn", "--from-clipboard", "--create"])
        XCTAssertEqual(fresh.credentialId, "zhipu-cn")
        XCTAssertEqual(fresh.fieldName, "zai-api-key")
        let explicit = try SaveCommand.parse(["--provider", "zhipu", "-c", "chosen", "--field", "zai-api-key", "--from-clipboard", "--create"])
        XCTAssertEqual(explicit.credentialId, "chosen")
        XCTAssertEqual(explicit.fieldName, "zai-api-key")
        let legacyCreate = try SaveCommand.parse(["--provider", "zhipu", "--from-clipboard", "--create"])
        XCTAssertEqual(legacyCreate.remainingFieldsNote, "", "primary alias must not be reported as another missing secret")
    }
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

extension SaveSuggestionCommandTests {
    /// yyt 2026-09-15：`--provider openai` 就够了——凭据 ID、字段名、格式检查都从模板来。
    func testProvider参数补全ID和字段名() throws {
        let command = try SaveCommand.parse(["--provider", "gpt", "--from-clipboard", "--create", "--purpose", "chat completions for the app"])
        XCTAssertEqual(command.request.credentialId, "openai")
        XCTAssertEqual(command.request.fieldName, "openai-api-key")
        XCTAssertEqual(command.request.provider, "openai")
        let explicit = try SaveCommand.parse(["--provider", "openai", "-c", "openai-prod", "--from-clipboard", "--create", "--purpose", "p"])
        XCTAssertEqual(explicit.request.credentialId, "openai-prod")
        XCTAssertThrowsError(try SaveCommand.parse(["--provider", "nope", "--from-clipboard", "--create"]))
        XCTAssertThrowsError(try SaveCommand.parse(["--from-clipboard", "--create"]), "没有模板就必须给 -c 和 --field")
        XCTAssertTrue(SaveCommand.validationNote(.valid, provider: "openai").contains("accepted"))
        XCTAssertTrue(SaveCommand.validationNote(.invalid, provider: "openai").contains("rejected"))
        XCTAssertTrue(SaveCommand.validationNote(.unreachable, provider: "openai").contains("could not"))
    }

    func testProviders命令列出并输出模板() {
        let list = ProvidersCommand.listText()
        XCTAssertTrue(list.contains("openai") && list.contains("anthropic") && list.contains("OPENAI_API_KEY"), list)
        XCTAssertTrue(list.contains("app-store-connect") && list.contains("3 fields"), list)
        XCTAssertTrue(list.contains("AWS_SECRET_ACCESS_KEY") && list.contains("AWS_ACCESS_KEY_ID"), list)
        let shown = ProvidersCommand.showText("claude")!
        XCTAssertTrue(shown.contains("console.anthropic.com") && shown.contains("\"validation\""), shown)
        XCTAssertNil(ProvidersCommand.showText("nope"))
    }

    func testProvider保存后明确列出还缺的必填字段() throws {
        let appStore = try SaveCommand.parse(["--provider", "app-store-connect", "--from-file", "/tmp/AuthKey.p8", "--create"])
        let appleNote = appStore.remainingFieldsNote
        XCTAssertTrue(appleNote.contains("key-id") && appleNote.contains("issuer-id"), appleNote)
        XCTAssertTrue(appleNote.contains("non-secret"), appleNote)

        let aws = try SaveCommand.parse(["--provider", "aws", "--from-clipboard", "--create"])
        XCTAssertTrue(aws.remainingFieldsNote.contains("aws-access-key-id"), aws.remainingFieldsNote)
        XCTAssertFalse(aws.remainingFieldsNote.contains("aws-session-token"), "optional fields must not block first use")

        let openAI = try SaveCommand.parse(["--provider", "openai", "--from-clipboard", "--create"])
        XCTAssertEqual(openAI.remainingFieldsNote, "")
    }
}
