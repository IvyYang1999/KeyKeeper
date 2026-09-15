import XCTest
@testable import KeyKeeperCore

final class ExistingModelProviderTests: XCTestCase {
    func test既有套餐与地区暴露精确路由而不是猜测BaseURL() throws {
        let expected = [
            "siliconflow-global": "https://api.siliconflow.com/v1",
            "deepseek": "https://api.deepseek.com",
            "openrouter": "https://openrouter.ai/api/v1",
            "xai": "https://api.x.ai/v1",
            "zhipu-cn": "https://open.bigmodel.cn/api/paas/v4",
            "zhipu-cn-coding": "https://open.bigmodel.cn/api/coding/paas/v4",
            "zai-global": "https://api.z.ai/api/paas/v4",
            "zai-global-coding": "https://api.z.ai/api/coding/paas/v4",
            "alibaba-bailian": "https://dashscope.aliyuncs.com/compatible-mode/v1",
            "alibaba-bailian-sg": "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
            "alibaba-bailian-us": "https://dashscope-us.aliyuncs.com/compatible-mode/v1",
            "alibaba-bailian-hk": "https://cn-hongkong.dashscope.aliyuncs.com/compatible-mode/v1",
            "alibaba-bailian-coding-cn": "https://coding.dashscope.aliyuncs.com/v1",
            "alibaba-bailian-token-cn": "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1",
        ]
        for (id, base) in expected {
            let template = try XCTUnwrap(ProviderCatalog.find(id), id)
            XCTAssertTrue(template.endpoints?.contains { $0.baseURL == base } == true, id)
            XCTAssertFalse(template.sources?.isEmpty ?? true, id)
            XCTAssertTrue(template.contractProblems.isEmpty, id)
        }
    }

    func testMiniMax一份值兼容官方客户端并保持套餐独立() throws {
        for id in ["minimax", "minimax-global", "minimax-token-plan-cn", "minimax-token-plan-global"] {
            let template = try XCTUnwrap(ProviderCatalog.find(id))
            XCTAssertTrue(template.primaryField.environmentNames.contains("MINIMAX_API_KEY"))
            XCTAssertTrue(template.primaryField.environmentNames.contains("ANTHROPIC_AUTH_TOKEN"))
            XCTAssertTrue(template.primaryField.environmentNames.contains("ANTHROPIC_API_KEY"))
            XCTAssertTrue(template.primaryField.environmentNames.contains("OPENAI_API_KEY"))
            XCTAssertTrue(template.endpoints?.contains { $0.baseURL.contains(id == "minimax" || id.hasSuffix("-cn") ? "api.minimaxi.com" : "api.minimax.io") } == true)
            XCTAssertNil(template.validation)
        }
    }

    func testCodingPlan完整协议与订阅前缀() throws {
        for (id, host) in [("zhipu-cn-coding", "open.bigmodel.cn"), ("zai-global-coding", "api.z.ai")] {
            let t = try XCTUnwrap(ProviderCatalog.find(id))
            XCTAssertTrue(t.endpoints?.contains { $0.protocolName == "OpenAI Responses" && $0.baseURL == "https://\(host)/api/v1" } == true)
            XCTAssertEqual(t.endpoints?.count, 3)
        }
        for id in ["minimax-token-plan-cn", "minimax-token-plan-global"] {
            let t = try XCTUnwrap(ProviderCatalog.find(id))
            XCTAssertEqual(t.prefixes, ["sk-cp-"])
            XCTAssertNotNil(t.shapeProblem(for: "sk-cpBROKEN-synthetic"))
            XCTAssertNil(t.shapeProblem(for: "sk-cp-synthetic-only"))
        }
    }

    func test路由元数据往返且不成为自动验证请求() throws {
        let template = try XCTUnwrap(ProviderCatalog.find("alibaba-bailian-sg"))
        let encoded = try JSONEncoder().encode(template)
        XCTAssertEqual(try JSONDecoder().decode(ProviderTemplate.self, from: encoded), template)
        XCTAssertNil(template.validation)
    }
}
