import XCTest
@testable import KeyKeeperCore

final class EnvImportTests: XCTestCase {
    func test解析dotenv常见写法() {
        let text = """
        # comment
        OPENAI_API_KEY=sk-synthetic-1234567890abcdef
        export STRIPE_KEY='sk_test_synthetic_000000'
        DATABASE_URL="postgres://user:pw@db.example/app" # trailing
        PORT=3000 # comment after space
        EMPTY=
        lower_case=nope
        BAD NAME=1
        OPENAI_API_KEY=sk-synthetic-second
        MULTI="a\\nb"

        """
        let entries = EnvFileParser.parse(text)
        XCTAssertEqual(entries.map(\.name), ["OPENAI_API_KEY", "STRIPE_KEY", "DATABASE_URL", "PORT", "EMPTY", "lower_case", "MULTI"])
        XCTAssertEqual(entries.first?.value, "sk-synthetic-second", "后出现的同名覆盖前面的")
        XCTAssertEqual(entries[1].value, "sk_test_synthetic_000000")
        XCTAssertEqual(entries[2].value, "postgres://user:pw@db.example/app")
        XCTAssertEqual(entries[3].value, "3000")
        XCTAssertEqual(entries[4].value, "")
        XCTAssertEqual(entries[6].value, "a\nb")
    }

    func test导入计划按名字和值的形状判断密钥并跳过不能还原的名字() {
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
        XCTAssertEqual(plan.secretNames, ["OPENAI_API_KEY", "DATABASE_URL", "SESSION"])
        XCTAssertEqual(plan.plainNames, ["PORT", "REGION"])
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
