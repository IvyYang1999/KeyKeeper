import XCTest
@testable import KeyKeeperCore

final class CloudModelProviderTests: XCTestCase {
    // AWS 的短期与长期 bearer key 生命周期不同，必须拆成两个合同。
    func testBedrockBearerVariantsStaySeparateAndRegionIsExplicitContext() throws {
        let providers = CloudModelProviderCatalog.all
        let short = try XCTUnwrap(providers.first { $0.id == "aws-bedrock-short-term" })
        let long = try XCTUnwrap(providers.first { $0.id == "aws-bedrock-long-term" })

        XCTAssertEqual(short.environmentName, "AWS_BEARER_TOKEN_BEDROCK")
        XCTAssertEqual(long.environmentName, "AWS_BEARER_TOKEN_BEDROCK")
        XCTAssertTrue(short.expiryNote?.contains("12") == true)
        XCTAssertFalse(long.expiryNote?.contains("12") == true)
        XCTAssertEqual(short.field(named: "aws-region")?.kind, .publicText)
        XCTAssertNil(short.validation)
        XCTAssertNil(long.validation)
        XCTAssertTrue(short.contractProblems.isEmpty)
        XCTAssertTrue(long.contractProblems.isEmpty)
    }

    // 所有已落库条目都必须是闭合合同；未核实的在线探测不能混进来。
    func testCatalogHasUniqueClosedContractsAndNoSpeculativeProbe() {
        let providers = CloudModelProviderCatalog.all
        XCTAssertEqual(providers.count, 17)
        XCTAssertEqual(Set(providers.map(\.id)).count, providers.count)
        XCTAssertTrue(providers.allSatisfy { $0.contractProblems.isEmpty })
        XCTAssertTrue(providers.allSatisfy { $0.validation == nil })
        XCTAssertTrue(providers.allSatisfy { $0.createURL.hasPrefix("https://") })
        XCTAssertTrue(providers.allSatisfy { !($0.sources ?? []).isEmpty })
    }

    // LongCat 没有官方 env；本地注入名必须显式揭示，不能伪装成自动兼容合同。
    func testLongCatLocalEnvironmentNameIsDisclosed() throws {
        let longCat = try provider("longcat")
        XCTAssertEqual(longCat.environmentName, "LONGCAT_API_KEY")
        XCTAssertEqual(longCat.primaryField.aliases, nil)
        XCTAssertTrue(longCat.primaryField.help.contains("KeyKeeper 本地注入名"))
        XCTAssertTrue(longCat.primaryField.help.contains("不是 LongCat 官方默认环境变量"))
        XCTAssertTrue(longCat.shownOnce)
        XCTAssertEqual(Set(longCat.endpoints?.map(\.baseURL) ?? []), [
            "https://api.longcat.chat/openai",
            "https://api.longcat.chat/anthropic",
        ])
    }

    // CN 官方集成额外读取 SDK_TOKEN；Global 未有同等一方合同，不能跨站推断。
    func testModelScopeSitesAndEnvironmentAliasesStaySeparate() throws {
        let cn = try provider("modelscope-cn")
        let global = try provider("modelscope-global")

        XCTAssertEqual(cn.primaryField.environmentNames,
                       ["MODELSCOPE_API_TOKEN", "MODELSCOPE_API_KEY", "MODELSCOPE_SDK_TOKEN"])
        XCTAssertEqual(global.primaryField.environmentNames, ["MODELSCOPE_API_TOKEN", "MODELSCOPE_API_KEY"])
        XCTAssertFalse(global.primaryField.environmentNames.contains("MODELSCOPE_SDK_TOKEN"))
        XCTAssertNotEqual(cn.createURL, global.createURL)
        XCTAssertNotEqual(cn.endpoints, global.endpoints)
    }

    // Qianfan Token 福利包与 Coding Plan 不能因兼容 OpenAI 而共用错误路径。
    func testQianfanContractsPreserveDomainAndPlanBoundaries() throws {
        let cn = try provider("baidu-qianfan-cn")
        let global = try provider("baidu-qianfan-global")
        let plan = try provider("baidu-qianfan-token-plan")

        XCTAssertEqual(cn.endpoints?.first?.baseURL, "https://qianfan.baidubce.com/v2")
        XCTAssertEqual(global.endpoints?.first?.baseURL, "https://api.baiduqianfan.ai/v1")
        XCTAssertEqual(plan.primaryField.environmentNames,
                       ["QIANFAN_TOKEN_PLAN_API_KEY", "QIANFAN_API_KEY"])
        XCTAssertFalse((plan.endpoints ?? []).contains { $0.baseURL.contains("/coding") })
        XCTAssertEqual(cn.field(named: "qianfan-appid")?.kind, .publicText)
    }

    // NVIDIA 托管推理 key 与 NGC registry/CLI key 是不同发行面。
    func testNvidiaCatalogAndNGCAreDifferentCredentials() throws {
        let catalog = try provider("nvidia-api-catalog")
        let ngc = try provider("nvidia-ngc")

        XCTAssertEqual(catalog.environmentName, "NVIDIA_API_KEY")
        XCTAssertEqual(ngc.environmentName, "NGC_API_KEY")
        XCTAssertEqual(catalog.endpoints?.first?.baseURL, "https://integrate.api.nvidia.com/v1")
        XCTAssertEqual(ngc.endpoints?.first?.baseURL, "https://nvcr.io")
        XCTAssertFalse(catalog.shownOnce)
        XCTAssertTrue(catalog.gates.contains { $0.contains("可能无法再次查看完整 key") })
        XCTAssertTrue(ngc.shownOnce)
    }

    // Step Plan 使用独立套餐/key，但官方明确说明兼容协议与标准 API 共用路径、无需额外前缀。
    func testStepPlanKeepsDedicatedCredentialButUsesSharedRoutes() throws {
        let standard = try provider("stepfun-api")
        let plan = try provider("stepfun-step-plan")

        XCTAssertEqual(standard.environmentName, "STEP_API_KEY")
        XCTAssertEqual(plan.environmentName, "STEP_API_KEY")
        XCTAssertEqual(Set(standard.endpoints?.map(\.baseURL) ?? []),
                       ["https://api.stepfun.ai/v1", "https://api.stepfun.ai"])
        XCTAssertEqual(Set(plan.endpoints?.map(\.baseURL) ?? []),
                       ["https://api.stepfun.ai/v1", "https://api.stepfun.ai"])
        XCTAssertNotEqual(standard.id, plan.id)
        XCTAssertTrue(plan.gates.contains { $0.contains("订阅") })
    }

    // MiMo 按量与三套 Token Plan 既不能混 key，也不能跨集群路由。
    func testMiMoPlanAndClusterContractsStaySeparate() throws {
        let payg = try provider("xiaomi-mimo-payg")
        XCTAssertEqual(payg.prefixes, ["sk-"])
        XCTAssertFalse(payg.shownOnce)

        let regions: [(String, String)] = [
            ("xiaomi-mimo-token-plan-cn", "中国"),
            ("xiaomi-mimo-token-plan-sg", "新加坡"),
            ("xiaomi-mimo-token-plan-eu", "欧洲"),
        ]
        for (id, region) in regions {
            let plan = try provider(id)
            XCTAssertEqual(plan.prefixes, ["tp-"])
            XCTAssertTrue(plan.shownOnce)
            XCTAssertEqual(plan.field(named: "mimo-region")?.kind, .publicText)
            XCTAssertTrue((plan.endpoints ?? []).allSatisfy { $0.region == region })
            XCTAssertFalse((plan.endpoints ?? []).contains { $0.baseURL.contains("api.xiaomimimo.com") })
        }
    }

    private func provider(_ id: String) throws -> ProviderTemplate {
        try XCTUnwrap(CloudModelProviderCatalog.all.first { $0.id == id })
    }
}
