import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-15：服务商模板——Agent 从「没有 key」走到「key 能用」的地图，以及 KeyKeeper 自己做的、值不经过 Agent 的验证。
final class ProviderTemplateTests: XCTestCase {
    func test验证默认不把权限不足误判成坏密钥() {
        let validation = ProviderValidation(
            url: "https://example.com/me", header: "Authorization", description: "reads identity")
        XCTAssertEqual(validation.invalidStatuses, [401])
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 403), validation: validation), .unreachable)
    }

    func test官方正则只检查形状且不回显值() {
        let field = ProviderFieldTemplate(
            name: "token", label: "Token", kind: .secretText, isPrimary: true,
            regularExpression: #"^pypi-[A-Za-z0-9_-]{85,}$"#)
        XCTAssertNil(field.shapeProblem(for: "pypi-" + String(repeating: "a", count: 85), providerName: "PyPI"))
        let bad = field.shapeProblem(for: "not-a-token", providerName: "PyPI")
        XCTAssertNotNil(bad)
        XCTAssertFalse(bad?.contains("not-a-token") == true)
    }

    func testCompleteProviderCatalogCoverage() {
        let expected: Set<String> = [
            "openai", "anthropic", "gemini", "supabase", "vercel", "github", "cloudflare", "stripe", "resend", "siliconflow",
            "siliconflow-global", "app-store-connect", "app-store-connect-individual", "apple-notary", "apple-notary-api-key", "apns", "developer-id", "developer-id-installer",
            "google-cloud", "ga4", "firebase-admin", "search-console",
            "openrouter", "deepseek", "groq", "xai", "kimi", "kimi-global", "kimi-code", "minimax", "minimax-global", "minimax-token-plan-cn", "minimax-token-plan-global",
            "zhipu-cn", "zhipu-cn-coding", "zai-global", "zai-global-coding", "alibaba-bailian", "alibaba-bailian-coding-cn", "alibaba-bailian-token-cn", "volcengine-ark", "volcengine-ark-coding",
            "neon", "neon-org", "railway", "railway-api", "render", "netlify", "flyio", "aws", "aws-sts", "azure", "cloudflare-account",
            "sentry", "posthog", "posthog-eu", "npm", "pypi", "pypi-test", "dockerhub", "dockerhub-oat", "gitlab",
            "twilio", "sendgrid", "sendgrid-eu", "mailgun", "slack", "slack-oauth-rotating", "feishu", "lark", "telegram",
            "atlascloud", "atlascloud-coding-plan", "compshare-modelverse-cn", "compshare-modelverse-global", "compshare-agent-plan",
            "ccsub", "micu-claude", "micu-codex", "rightcode-codex", "cubence", "crazyrouter", "dmxapi-cn", "dmxapi-global", "dmxapi-ssvip", "aihubmix", "amux", "cherryin",
            "aws-bedrock-short-term", "aws-bedrock-long-term", "baidu-qianfan-cn", "baidu-qianfan-global", "baidu-qianfan-token-plan",
            "nvidia-api-catalog", "nvidia-ngc", "modelscope-cn", "modelscope-global", "novita-ai", "longcat", "stepfun-api", "stepfun-step-plan",
            "xiaomi-mimo-payg", "xiaomi-mimo-token-plan-cn", "xiaomi-mimo-token-plan-sg", "xiaomi-mimo-token-plan-eu",
            "opencode-zen", "opencode-go", "pipellm", "relaxycode", "therouter",
            "alibaba-bailian-sg", "alibaba-bailian-us", "alibaba-bailian-hk",
            "zenmux-payg", "zenmux-builder",
        ]
        XCTAssertEqual(Set(ProviderCatalog.all.map(\.id)), expected)
        XCTAssertEqual(ProviderCatalog.all.count, expected.count)
    }

    func testZenMux按量与订阅分别建模板且不把订阅当按量() throws {
        let payg = try XCTUnwrap(ProviderCatalog.find("zenmux-payg"))
        let builder = try XCTUnwrap(ProviderCatalog.find("zenmux-builder"))
        XCTAssertNotEqual(payg.createURL, builder.createURL)
        XCTAssertEqual(payg.environmentName, "ZENMUX_API_KEY")
        XCTAssertEqual(builder.environmentName, "ZENMUX_API_KEY")
        XCTAssertTrue(builder.minimalPermission.contains("subscription"))
        XCTAssertTrue(payg.minimalPermission.contains("pay-as-you-go"))
        XCTAssertNil(payg.validation)
        XCTAssertNil(builder.validation)
    }

    func testRepresentativeBundleFieldsUseOfficialEnvironmentNames() throws {
        func environment(_ provider: String, _ field: String) throws -> String? {
            try XCTUnwrap(ProviderCatalog.find(provider)).field(named: field)?.environmentName
        }
        XCTAssertEqual(try environment("google-cloud", "google-application-credentials"), "GOOGLE_APPLICATION_CREDENTIALS")
        XCTAssertEqual(try environment("aws", "aws-secret-access-key"), "AWS_SECRET_ACCESS_KEY")
        XCTAssertEqual(try environment("aws", "aws-access-key-id"), "AWS_ACCESS_KEY_ID")
        XCTAssertEqual(try environment("azure", "azure-client-secret"), "AZURE_CLIENT_SECRET")
        XCTAssertEqual(try environment("twilio", "twilio-api-secret"), "TWILIO_API_SECRET")
        XCTAssertEqual(try environment("pypi", "twine-password"), "TWINE_PASSWORD")
    }

    func testKimi开放平台与Coding服务不会混用密钥或入口() throws {
        let china = try XCTUnwrap(ProviderCatalog.find("kimi"))
        XCTAssertEqual(china.name, "Kimi · Open Platform (China)")
        XCTAssertEqual(china.fieldName, "moonshot-api-key")
        XCTAssertEqual(china.createURL, "https://platform.moonshot.cn/console/api-keys")
        XCTAssertEqual(china.validation?.url, "https://api.moonshot.cn/v1/models")

        let global = try XCTUnwrap(ProviderCatalog.find("kimi-global"))
        XCTAssertEqual(global.name, "Kimi · API Platform (Global)")
        XCTAssertEqual(global.fieldName, "moonshot-api-key")
        XCTAssertEqual(global.createURL, "https://platform.kimi.ai/console/account")
        XCTAssertEqual(global.validation?.url, "https://api.moonshot.ai/v1/models")

        let coding = try XCTUnwrap(ProviderCatalog.find("kimi-code"))
        XCTAssertEqual(coding.name, "Kimi · Kimi Code")
        XCTAssertEqual(coding.fieldName, "kimi-api-key")
        XCTAssertEqual(coding.createURL, "https://www.kimi.com/code/console")
        XCTAssertNil(coding.validation, "没有官方只读验证合同前，不能拿普通开放平台 endpoint 试 Coding key")
        XCTAssertTrue(coding.minimalPermission.contains("not interchangeable"))
        XCTAssertTrue(coding.minimalPermission.contains("https://api.kimi.com/coding/v1"))
        XCTAssertEqual(ProviderCatalog.find("moonshot")?.id, "kimi", "旧 alias 继续指向原来的中国开放平台")
        XCTAssertEqual(ProviderCatalog.find("kimi-for-coding")?.id, "kimi-code")
    }

    func test智谱国内海外与CodingPlan是四个明确合同() throws {
        let china = try XCTUnwrap(ProviderCatalog.find("zhipu"))
        XCTAssertEqual(china.name, "智谱 · 开放平台 (中国)")
        XCTAssertEqual(china.fieldName, "zai-api-key")
        XCTAssertEqual(china.field(named: "zhipuai-api-key")?.name, "zai-api-key", "旧字段名仍解析到同一份值")
        XCTAssertEqual(china.createURL, "https://bigmodel.cn/usercenter/proj-mgmt/apikeys")
        XCTAssertTrue(china.minimalPermission.contains("https://open.bigmodel.cn/api/paas/v4"))

        let chinaCoding = try XCTUnwrap(ProviderCatalog.find("zhipu-coding"))
        XCTAssertEqual(chinaCoding.name, "智谱 · GLM Coding Plan (中国)")
        XCTAssertEqual(chinaCoding.fieldName, "zai-api-key")
        XCTAssertEqual(chinaCoding.createURL, "https://bigmodel.cn/coding-plan/personal/overview")
        XCTAssertNil(chinaCoding.validation)
        XCTAssertTrue(chinaCoding.minimalPermission.contains("https://open.bigmodel.cn/api/coding/paas/v4"))
        XCTAssertTrue(chinaCoding.minimalPermission.contains("not interchangeable"))

        let global = try XCTUnwrap(ProviderCatalog.find("zai"))
        XCTAssertEqual(global.name, "Z.AI · API (Global)")
        XCTAssertEqual(global.createURL, "https://z.ai/manage-apikey/apikey-list")
        XCTAssertTrue(global.minimalPermission.contains("https://api.z.ai/api/paas/v4"))

        let globalCoding = try XCTUnwrap(ProviderCatalog.find("zai-coding"))
        XCTAssertEqual(globalCoding.name, "Z.AI · GLM Coding Plan (Global)")
        XCTAssertEqual(globalCoding.createURL, "https://z.ai/manage-apikey/apikey-list")
        XCTAssertNil(globalCoding.validation)
        XCTAssertTrue(globalCoding.minimalPermission.contains("https://api.z.ai/api/coding/paas/v4"))
        XCTAssertTrue(globalCoding.minimalPermission.contains("not interchangeable"))
        XCTAssertEqual(ProviderCatalog.find("智谱")?.id, "zhipu-cn", "旧 alias 继续指向国内一般 API")
        XCTAssertEqual(ProviderCatalog.find("z.ai")?.id, "zai-global")
        XCTAssertNil(china.validation, "官方未提供可依赖的只读 models 合同")
    }


    func test高风险服务商按凭据身份拆分而不是只靠说明文字() throws {
        XCTAssertNotNil(ProviderCatalog.find("siliconflow-global"))
        XCTAssertNotNil(ProviderCatalog.find("minimax-global"))
        XCTAssertNotNil(ProviderCatalog.find("minimax-token-plan-cn"))
        XCTAssertNotNil(ProviderCatalog.find("minimax-token-plan-global"))
        XCTAssertNotNil(ProviderCatalog.find("alibaba-bailian-coding-cn"))
        XCTAssertNotNil(ProviderCatalog.find("alibaba-bailian-token-cn"))
        XCTAssertNotNil(ProviderCatalog.find("volcengine-ark-coding"))
        XCTAssertNotNil(ProviderCatalog.find("cloudflare-account"))
        XCTAssertNotNil(ProviderCatalog.find("railway-api"))
        XCTAssertNotNil(ProviderCatalog.find("aws-sts"))
        XCTAssertNotNil(ProviderCatalog.find("pypi-test"))
        XCTAssertNotNil(ProviderCatalog.find("dockerhub-oat"))
        XCTAssertNotNil(ProviderCatalog.find("lark"))
        XCTAssertNotNil(ProviderCatalog.find("app-store-connect-individual"))
        XCTAssertNotNil(ProviderCatalog.find("apple-notary-api-key"))
        XCTAssertNotNil(ProviderCatalog.find("posthog-eu"))
        XCTAssertNotNil(ProviderCatalog.find("slack-oauth-rotating"))

        let projectRailway = try XCTUnwrap(ProviderCatalog.find("railway"))
        XCTAssertEqual(projectRailway.environmentName, "RAILWAY_TOKEN")
        XCTAssertFalse(projectRailway.createURL.contains("/account/tokens"))
        XCTAssertEqual(ProviderCatalog.find("railway-api")?.environmentName, "RAILWAY_API_TOKEN")

        let longLivedAWS = try XCTUnwrap(ProviderCatalog.find("aws"))
        XCTAssertEqual(longLivedAWS.field(named: "aws-access-key-id")?.prefixes, ["AKIA"])
        XCTAssertNil(longLivedAWS.field(named: "aws-session-token"))
        let temporaryAWS = try XCTUnwrap(ProviderCatalog.find("aws-sts"))
        XCTAssertEqual(temporaryAWS.field(named: "aws-access-key-id")?.prefixes, ["ASIA"])
        XCTAssertEqual(temporaryAWS.field(named: "aws-session-token")?.required, true)
        XCTAssertEqual(longLivedAWS.field(named: "aws-access-key-id")?.regularExpression,
                       #"^AKIA[A-Z0-9]{16}$"#)
        XCTAssertEqual(temporaryAWS.field(named: "aws-access-key-id")?.regularExpression,
                       #"^ASIA[A-Z0-9]{16}$"#)

        let twilio = try XCTUnwrap(ProviderCatalog.find("twilio"))
        XCTAssertEqual(twilio.field(named: "twilio-api-key")?.regularExpression,
                       #"^SK[0-9a-fA-F]{32}$"#)
        XCTAssertEqual(twilio.field(named: "twilio-account-sid")?.regularExpression,
                       #"^AC[0-9a-fA-F]{32}$"#)

        XCTAssertEqual(ProviderCatalog.find("pypi")?.primaryField.regularExpression,
                       #"^pypi-[A-Za-z0-9_-]{85,}$"#)
        XCTAssertEqual(ProviderCatalog.find("telegram")?.primaryField.regularExpression,
                       #"^[0-9]+:[A-Za-z0-9_-]+$"#)
    }
    func testProviderV2FieldsDescribeAppleBundlesAndLocalIdentity() throws {
        let appStore = try XCTUnwrap(ProviderCatalog.find("app-store-connect"))
        XCTAssertEqual(appStore.primaryField.kind, .secretFile)
        XCTAssertEqual(appStore.primaryField.fileFormat, .applePrivateKeyP8)
        XCTAssertEqual(Set(appStore.fields.map(\.name)), ["private-key", "key-id", "issuer-id"])
        XCTAssertEqual(appStore.fields.first(where: { $0.name == "issuer-id" })?.kind, .publicText)

        let notary = try XCTUnwrap(ProviderCatalog.find("apple-notary"))
        XCTAssertEqual(Set(notary.fields.map(\.name)), ["apple-app-specific-password", "apple-id", "apple-team-id"])
        XCTAssertEqual(notary.primaryField.kind, .secretText)

        let apns = try XCTUnwrap(ProviderCatalog.find("apns"))
        XCTAssertEqual(apns.primaryField.fileFormat, .applePrivateKeyP8)
        XCTAssertEqual(Set(apns.fields.map(\.name)), ["private-key", "key-id", "team-id"])

        let developerID = try XCTUnwrap(ProviderCatalog.find("developer-id"))
        XCTAssertEqual(developerID.primaryField.kind, .localIdentity)
        XCTAssertFalse(developerID.primaryField.isSaveableSecret)
        XCTAssertNil(developerID.primaryField.fileFormat)
    }

    func testEveryV2TemplateHasOnePrimaryFieldAndNoBrokenFieldContracts() {
        for template in ProviderCatalog.all {
            XCTAssertEqual(template.fields.filter(\.isPrimary).count, 1, template.id)
            XCTAssertEqual(template.primaryField.name, template.fieldName, template.id)
            XCTAssertEqual(Set(template.fields.map(\.name)).count, template.fields.count, template.id)
            XCTAssertTrue(template.contractProblems.isEmpty, "\(template.id): \(template.contractProblems)")
        }
    }
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
        let documentedFixture = ProviderTemplate(
            id: "fixture", name: "Fixture", fieldName: "api-key",
            createURL: "https://example.com/keys", gates: ["Create key"],
            minimalPermission: "Fixture only", prefixes: ["sk-"], minChars: 10,
            shownOnce: true, verified: "2026-09-15")
        XCTAssertNil(documentedFixture.shapeProblem(for: "sk-1234567"))
        let wrongPrefix = documentedFixture.shapeProblem(for: "AKIA1234567890")!
        XCTAssertTrue(wrongPrefix.contains("sk-") && !wrongPrefix.contains("AKIA"), wrongPrefix)
        let short = documentedFixture.shapeProblem(for: "sk-short")!
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

    /// A scoped Supabase PAT can be genuine while lacking projects:read. A 403 must not tell the
    /// user that the copied token is wrong; only 401 proves authentication failed.
    func testSupabase受限令牌403不误判成假密钥() throws {
        let supabase = try XCTUnwrap(ProviderCatalog.find("supabase"))
        let validation = try XCTUnwrap(supabase.validation)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 401), validation: validation), .invalid)
        XCTAssertEqual(ProviderProbe.outcome(.init(status: 403), validation: validation), .unreachable)
        XCTAssertTrue(supabase.minimalPermission.lowercased().contains("scoped"))
    }

    func test十个模板都在_字段名就是SDK读的变量() {
        let expected = ["openai": "OPENAI_API_KEY", "anthropic": "ANTHROPIC_API_KEY", "gemini": "GEMINI_API_KEY",
                        "supabase": "SUPABASE_ACCESS_TOKEN", "vercel": "VERCEL_TOKEN", "github": "GITHUB_TOKEN",
                        "cloudflare": "CLOUDFLARE_API_TOKEN", "stripe": "STRIPE_API_KEY", "resend": "RESEND_API_KEY",
                        "siliconflow": "SILICONFLOW_API_KEY"]
        XCTAssertGreaterThanOrEqual(ProviderCatalog.all.count, expected.count)
        for (id, env) in expected {
            let template = ProviderCatalog.find(id)
            XCTAssertEqual(template?.environmentName, env, id)
            XCTAssertEqual(template?.verified, "2026-09-15", id)
            if id == "cloudflare" {
                XCTAssertNil(template?.validation, "Cloudflare HTTP 200 still needs a JSON active-status check")
            } else {
                XCTAssertNotNil(template?.validation, id)
            }
        }
        XCTAssertEqual(ProviderCatalog.find("硅基流动")?.id, "siliconflow")
        XCTAssertNil(ProviderCatalog.find("github")!.shapeProblem(for: "ghp_" + String(repeating: "a", count: 36)))
        XCTAssertNil(ProviderCatalog.find("stripe")!.shapeProblem(for: "rk_test_" + String(repeating: "a", count: 30)))
        XCTAssertNotNil(ProviderCatalog.find("stripe")!.shapeProblem(for: "pk_test_" + String(repeating: "a", count: 30)), "公开 key 不是密钥")
    }

    func test所有在线探针都不会把403权限不足当成坏密钥() {
        for template in ProviderCatalog.all {
            if let validation = template.validation {
                XCTAssertFalse(validation.invalidStatuses.contains(403), template.id)
            }
        }
    }

    func test模板可编码_给Agent读() throws {
        let data = try JSONEncoder().encode(ProviderCatalog.all)
        let back = try JSONDecoder().decode([ProviderTemplate].self, from: data)
        XCTAssertEqual(back, ProviderCatalog.all)
    }
}
