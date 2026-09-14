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

    func test形状检查_多前缀任一即可() {
        var template = ProviderCatalog.find("openai")!
        template.prefixes = ["ghp_", "github_pat_"]
        XCTAssertNil(template.shapeProblem(for: "github_pat_" + String(repeating: "a", count: 80)))
        XCTAssertNil(template.shapeProblem(for: "ghp_" + String(repeating: "a", count: 36)))
        XCTAssertTrue(template.shapeProblem(for: "sk-" + String(repeating: "a", count: 80))!.contains("ghp_ or github_pat_"))
        template.prefixes = []
        XCTAssertNil(template.shapeProblem(for: String(repeating: "a", count: 80)), "没有前缀规则就只看长度")
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
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 200), validation: validation), .valid)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 401), validation: validation), .invalid)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 429), validation: validation), .unreachable)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 503), validation: validation), .unreachable)
        struct Fail: ProbeTransport { func send(_ request: URLRequest) async throws -> ProbeReply { throw URLError(.notConnectedToInternet) } }
        let failed = await ProviderProbe.run(validation, value: "k", transport: Fail())
        XCTAssertEqual(failed, .unreachable)
        struct OK: ProbeTransport { func send(_ request: URLRequest) async throws -> ProbeReply { .init(status: 200) } }
        let ok = await ProviderProbe.run(validation, value: "k", transport: OK())
        XCTAssertEqual(ok, .valid)
    }

    /// Resend 的「仅发送」key（我们推荐的最小权限）打只读接口回 401 restricted_api_key：那是「真 key 但不许列」，不是「错 key」。
    func test响应体里的错误名能把401改判为有效() {
        let resend = ProviderCatalog.find("resend")!.validation!
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 401, body: #"{"name":"restricted_api_key","message":"This API key is restricted to only send emails"}"#), validation: resend), .valid)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 401, body: #"{"name":"missing_api_key"}"#), validation: resend), .invalid)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 200), validation: resend), .valid)
        let gemini = ProviderCatalog.find("gemini")!.validation!
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 400), validation: gemini), .invalid, "Gemini 无效 key 回 400")
        let stripe = ProviderCatalog.find("stripe")!.validation!
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 403), validation: stripe), .unreachable, "受限 key 缺 Balance:Read 不算错 key")
    }

    func test十个模板都在_字段名就是SDK读的变量() {
        let expected = ["openai": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "gemini": "GEMINI_API_KEY",
                        "supabase": "SUPABASE_ACCESS_TOKEN", "vercel": "VERCEL_TOKEN", "github": "GITHUB_TOKEN",
                        "cloudflare": "CLOUDFLARE_API_TOKEN", "stripe": "STRIPE_API_KEY", "resend": "RESEND_API_KEY",
                        "siliconflow": "SILICONFLOW_API_KEY"]
        XCTAssertEqual(ProviderCatalog.all.count, expected.count)
        for (id, env) in expected {
            let template = ProviderCatalog.find(id)
            XCTAssertEqual(template?.environmentName, env, id)
            XCTAssertEqual(template?.verified, "2026-09-15", id)
            XCTAssertNotNil(template?.validation, id)
        }
        XCTAssertEqual(ProviderCatalog.find("硅基流动")?.id, "siliconflow")
        XCTAssertNil(ProviderCatalog.find("github")!.shapeProblem(for: "ghp_" + String(repeating: "a", count: 36)))
        XCTAssertNil(ProviderCatalog.find("stripe")!.shapeProblem(for: "rk_test_" + String(repeating: "a", count: 30)))
        XCTAssertNotNil(ProviderCatalog.find("stripe")!.shapeProblem(for: "pk_test_" + String(repeating: "a", count: 30)), "公开 key 不是密钥")
    }

    func test模板可编码_给Agent读() throws {
        let data = try JSONEncoder().encode(ProviderCatalog.all)
        let back = try JSONDecoder().decode([ProviderTemplate].self, from: data)
        XCTAssertEqual(back, ProviderCatalog.all)
    }
}
