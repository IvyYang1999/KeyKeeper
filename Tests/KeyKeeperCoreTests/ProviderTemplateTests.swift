import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-15：服务商模板——Agent 从「没有 key」走到「key 能用」的地图，以及 KeyKeeper 自己做的、值不经过 Agent 的验证。
final class ProviderTemplateTests: XCTestCase {
    func test目录完整_id和别名不重复_地址都是https_验证请求形状合理() {
        var seen = Set<String>()
        for template in ProviderCatalog.all {
            for key in [template.id] + template.aliases {
                XCTAssertTrue(seen.insert(key).inserted, "重复的 id/别名 \(key)")
            }
            XCTAssertTrue(template.createURL.hasPrefix("https://"), template.id)
            XCTAssertTrue(CredentialNames.isValidFieldName(template.fieldName), template.fieldName)
            XCTAssertFalse(EnvironmentVariableName.isReserved(fieldName: template.fieldName))
            XCTAssertFalse(template.gates.isEmpty && template.minimalPermission.isEmpty)
            if let validation = template.validation {
                XCTAssertTrue(validation.url.hasPrefix("https://"), template.id)
                XCTAssertEqual(validation.method, "GET", "验证必须无副作用")
                XCTAssertFalse(validation.header.isEmpty)
                XCTAssertFalse(validation.okStatuses.isEmpty)
            }
        }
        XCTAssertEqual(ProviderCatalog.find("GPT")?.id, "openai")
        XCTAssertEqual(ProviderCatalog.find(" claude ")?.id, "anthropic")
        XCTAssertNil(ProviderCatalog.find("nope"))
        XCTAssertEqual(ProviderCatalog.find("openai")?.environmentName, "OPENAI_API_KEY", "字段名就是 SDK 读的变量")
        XCTAssertEqual(ProviderCatalog.find("anthropic")?.environmentName, "ANTHROPIC_API_KEY")
    }

    func test形状检查_前缀和最短长度_出错信息不带值() {
        let openai = ProviderCatalog.find("openai")!
        XCTAssertNil(openai.shapeProblem(for: "sk-proj-" + String(repeating: "a", count: 100)))
        let wrongPrefix = openai.shapeProblem(for: "AKIA" + String(repeating: "a", count: 100))!
        XCTAssertTrue(wrongPrefix.contains("sk-") && !wrongPrefix.contains("AKIA"), wrongPrefix)
        let short = openai.shapeProblem(for: "sk-short")!
        XCTAssertTrue(short.contains("at least") && !short.contains("sk-short"), short)
    }

    func test验证请求_值只在一个请求头里_不在URL不在body_只走https() throws {
        let validation = ProviderCatalog.find("anthropic")!.validation!
        let request = try XCTUnwrap(ProviderProbe.request(validation, value: "sk-ant-VALUE"))
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-VALUE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertFalse(request.url!.absoluteString.contains("VALUE"))
        let openai = ProviderCatalog.find("openai")!.validation!
        XCTAssertEqual(ProviderProbe.request(openai, value: "k")?.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        var http = openai; http.url = "http://api.openai.com/v1/models"
        XCTAssertNil(ProviderProbe.request(http, value: "k"), "明文 http 一律不发")
    }

    func test结果映射_200有效_401无效_其余算不可达_传输失败不可达() async {
        let validation = ProviderCatalog.find("openai")!.validation!
        XCTAssertEqual(ProviderProbe.outcome(status: 200, validation: validation), .valid)
        XCTAssertEqual(ProviderProbe.outcome(status: 401, validation: validation), .invalid)
        XCTAssertEqual(ProviderProbe.outcome(status: 429, validation: validation), .unreachable)
        XCTAssertEqual(ProviderProbe.outcome(status: 503, validation: validation), .unreachable)
        struct Fail: ProbeTransport { func status(for request: URLRequest) async throws -> Int { throw URLError(.notConnectedToInternet) } }
        let failed = await ProviderProbe.run(validation, value: "k", transport: Fail())
        XCTAssertEqual(failed, .unreachable)
        struct OK: ProbeTransport { func status(for request: URLRequest) async throws -> Int { 200 } }
        let ok = await ProviderProbe.run(validation, value: "k", transport: OK())
        XCTAssertEqual(ok, .valid)
    }

    func test模板可编码_给Agent读() throws {
        let data = try JSONEncoder().encode(ProviderCatalog.all)
        let back = try JSONDecoder().decode([ProviderTemplate].self, from: data)
        XCTAssertEqual(back, ProviderCatalog.all)
    }
}
