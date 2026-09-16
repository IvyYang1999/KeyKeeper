import XCTest
@testable import KeyKeeperCore

final class EnvImportTests: XCTestCase {
    // 【曾经的 bug】名字与长度不能证明一个值可以公开到 meta / SDK。全部是假数据。
    func test导入值默认全部保密包括短密码和带凭据的URL() {
        let entries = [
            EnvEntry(name: "SESSION", value: "synthetic", line: 1),
            EnvEntry(name: "DATABASE_URL", value: "redis://synthetic@localhost", line: 2),
            EnvEntry(name: "WEBHOOK_URL", value: "https://example.test/hook/synthetic", line: 3),
            EnvEntry(name: "PORT", value: "3000", line: 4),
        ]
        let plan = EnvImportPlan.make(entries)
        XCTAssertEqual(plan.secretNames, entries.map(\.name))
        XCTAssertTrue(plan.plainNames.isEmpty)
    }

    // 【曾经的 bug】转义引号不能被当作字符串结束而截断。
    func test转义引号和反斜杠保真() throws {
        let entries = try EnvFileParser.parse(#"VALUE="ab\"cd\\ef" # comment"#)
        XCTAssertEqual(entries.first?.value, #"ab"cd\ef"#)
    }

    // 不支持的语法必须整份拒绝，不能返回一个看似成功的残缺凭据。
    func test未闭合引号多行和尾随内容拒绝() {
        for text in ["VALUE=\"first\nsecond\"", "VALUE='unfinished", "VALUE=\"ok\"trailing", "not an assignment"] {
            XCTAssertThrowsError(try EnvFileParser.parse(text))
        }
    }

    func test解析dotenv常见写法() throws {
        let text = """
        # comment
        OPENAI_API_KEY=sk-synthetic-1234567890abcdef
        export STRIPE_KEY='sk_test_synthetic_000000'
        DATABASE_URL="postgres://user:pw@db.example/app" # trailing
        PORT=3000 # comment after space
        EMPTY=
        lower_case=nope
        OPENAI_API_KEY=sk-synthetic-second
        MULTI="a\\nb"

        """
        let entries = try EnvFileParser.parse(text)
        XCTAssertEqual(entries.map(\.name), ["OPENAI_API_KEY", "STRIPE_KEY", "DATABASE_URL", "PORT", "EMPTY", "lower_case", "MULTI"])
        XCTAssertEqual(entries.first?.value, "sk-synthetic-second", "后出现的同名覆盖前面的")
        XCTAssertEqual(entries[1].value, "sk_test_synthetic_000000")
        XCTAssertEqual(entries[2].value, "postgres://user:pw@db.example/app")
        XCTAssertEqual(entries[3].value, "3000")
        XCTAssertEqual(entries[4].value, "")
        XCTAssertEqual(entries[6].value, "a\nb")
    }

    func test导入计划全部保密并跳过不能还原的名字() {
        let plan = EnvImportPlan.make([
            .init(name: "OPENAI_API_KEY", value: "sk-synthetic-1234567890abcdef", line: 1),
            .init(name: "DATABASE_URL", value: "postgres://user:pw@db.example/app", line: 2),
            .init(name: "PORT", value: "3000", line: 3),
            .init(name: "REGION", value: "us-east-1", line: 4),
            .init(name: "SESSION", value: "AbCdEf0123456789GhIjKlMn", line: 5),
            .init(name: "EMPTY", value: "  ", line: 6),
            .init(name: "lower_case", value: "x", line: 7),
            .init(name: "PATH", value: "/bin", line: 8),
            .init(name: "NODE_OPTIONS", value: "--inspect", line: 9),
        ])
        XCTAssertEqual(plan.fields.map(\.fieldName), ["openai-api-key", "database-url", "port", "region", "session"])
        XCTAssertEqual(plan.secretNames, ["OPENAI_API_KEY", "DATABASE_URL", "PORT", "REGION", "SESSION"])
        XCTAssertTrue(plan.plainNames.isEmpty)
        XCTAssertEqual(plan.skipped.map(\.name), ["EMPTY", "lower_case", "PATH", "NODE_OPTIONS"])
        for field in plan.fields {
            XCTAssertEqual(EnvironmentVariableName.from(fieldName: field.fieldName), field.name, "run 注入时变量名必须原样回来")
        }
    }

    func test请求只接受绝对路径的env文件和合法ID() {
        XCTAssertNoThrow(try EnvImportRequest(credentialId: "my-app", filePath: "/tmp/p/.env").validate())
        XCTAssertNoThrow(try EnvImportRequest(credentialId: "my-app", filePath: "/tmp/p/.env.local").validate())
        XCTAssertNoThrow(try EnvImportRequest(credentialId: "my-app", filePath: "/tmp/p/staging.env").validate())
        XCTAssertThrowsError(try EnvImportRequest(credentialId: "my-app", filePath: "/tmp/p/config.py").validate())
        XCTAssertThrowsError(try EnvImportRequest(credentialId: "my-app", filePath: ".env").validate())
        XCTAssertThrowsError(try EnvImportRequest(credentialId: "My App", filePath: "/tmp/.env").validate())
        XCTAssertThrowsError(try EnvImportRequest(credentialId: "app", filePath: "/tmp/.env", label: "  ").validate())
    }

    func testIPC信封往返() throws {
        let request = IPCRequest.envImport(.init(credentialId: "app", filePath: "/tmp/.env", label: "My App"))
        let data = try JSONEncoder().encode(request)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"envImport\""))
        guard case .envImport(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded.label, "My App")
    }
}
