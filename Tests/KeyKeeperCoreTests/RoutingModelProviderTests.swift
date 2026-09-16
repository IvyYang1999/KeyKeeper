import XCTest
@testable import KeyKeeperCore

final class RoutingModelProviderTests: XCTestCase {
    private func find(_ id: String) -> ProviderTemplate? {
        RoutingModelProviderCatalog.all.first { $0.id == id || $0.aliases.contains(id) }
    }

    func testOpenCodeConsole保留Zen路由且不用上游厂商变量() throws {
        let provider = try XCTUnwrap(find("opencode-zen"))
        XCTAssertEqual(provider.name, "OpenCode · Zen (Console)")
        XCTAssertEqual(provider.environmentName, "OPENCODE_API_KEY")
        XCTAssertEqual(provider.createURL, "https://opencode.ai/console/")
        XCTAssertEqual(provider.endpoints, [
            ProviderEndpoint("OpenAI Responses / Chat Completions", "https://opencode.ai/zen/v1"),
            ProviderEndpoint("Anthropic Messages", "https://opencode.ai/zen/v1"),
            ProviderEndpoint("Gemini", "https://opencode.ai/zen/v1"),
        ])
        XCTAssertNil(provider.validation)
        XCTAssertFalse(provider.shownOnce)
        XCTAssertTrue(provider.prefixes.isEmpty)
        XCTAssertTrue(provider.contractProblems.isEmpty)
    }

    func testOpenCodeGo与按量Console保持独立路由合同() throws {
        let provider = try XCTUnwrap(find("opencode-go"))
        XCTAssertEqual(provider.environmentName, "OPENCODE_API_KEY")
        XCTAssertEqual(provider.createURL, "https://opencode.ai/console/")
        XCTAssertEqual(provider.endpoints, [
            ProviderEndpoint("OpenAI Responses / Chat Completions", "https://opencode.ai/zen/go/v1"),
            ProviderEndpoint("Anthropic Messages", "https://opencode.ai/zen/go/v1"),
        ])
        XCTAssertTrue(provider.minimalPermission.contains("未确认"))
        XCTAssertTrue(provider.minimalPermission.contains("不可互换"))
        XCTAssertNil(provider.validation)
    }

    func testPipeLLM记录原生和转换路由但不主动探测() throws {
        let provider = try XCTUnwrap(find("pipellm"))
        XCTAssertEqual(provider.environmentName, "PIPELLM_API_KEY")
        XCTAssertEqual(provider.createURL, "https://console.pipellm.ai/")
        XCTAssertEqual(provider.endpoints, [
            ProviderEndpoint("Native public routes", "https://api.pipellm.ai"),
            ProviderEndpoint("OpenAI converter", "https://api.pipellm.ai/openai/v1"),
            ProviderEndpoint("Anthropic converter", "https://api.pipellm.ai/anthropic"),
            ProviderEndpoint("Gemini converter", "https://api.pipellm.ai/gemini"),
        ])
        XCTAssertNil(provider.validation)
    }

    func testRelaxyCode只登记官方Codex文档实际声明的路由() throws {
        let provider = try XCTUnwrap(find("relaxycode"))
        XCTAssertEqual(provider.environmentName, "OPENAI_API_KEY")
        XCTAssertEqual(provider.createURL, "https://www.relaxycode.com/dashboard/api-keys")
        XCTAssertEqual(provider.endpoints, [
            ProviderEndpoint("OpenAI Responses for Codex", "https://api.relaxycode.com/v1"),
        ])
        XCTAssertTrue(provider.minimalPermission.contains("套餐或余额"))
        XCTAssertTrue(provider.minimalPermission.contains("DMXAPI"))
        XCTAssertNil(provider.validation)
    }

    func testTheRouter环境别名只覆盖官方ClaudeCode映射() throws {
        let provider = try XCTUnwrap(find("therouter"))
        XCTAssertEqual(provider.environmentName, "THEROUTER_API_KEY")
        XCTAssertEqual(provider.primaryField.environmentNames, ["THEROUTER_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(provider.field(named: "anthropic-api-key"), "官方要求该变量置空，不能映射同一 secret")
        XCTAssertEqual(provider.createURL, "https://dashboard.therouter.ai/")
        XCTAssertEqual(provider.endpoints, [
            ProviderEndpoint("OpenAI-compatible", "https://api.therouter.ai/v1"),
            ProviderEndpoint("Anthropic Messages / Claude Code", "https://api.therouter.ai"),
        ])
        XCTAssertNil(provider.validation)
    }

    func test未闭合发行方身份的EFlowCode不进入可保存目录() {
        XCTAssertNil(find("eflowcode"))
        XCTAssertNil(find("e-flowcode"))
    }

    func test所有已接路由模板不猜密钥形状展示和有效期() {
        XCTAssertEqual(Set(RoutingModelProviderCatalog.all.map(\.id)), [
            "opencode-zen", "opencode-go", "pipellm", "relaxycode", "therouter",
        ])
        for provider in RoutingModelProviderCatalog.all {
            XCTAssertFalse(provider.shownOnce, provider.id)
            XCTAssertTrue(provider.prefixes.isEmpty, provider.id)
            XCTAssertNil(provider.minChars, provider.id)
            XCTAssertEqual(provider.expiryNote,
                "未确认统一有效期；以创建页面显示的实际日期为准，未知时不要猜测。", provider.id)
            XCTAssertTrue(provider.contractProblems.isEmpty, "\(provider.id): \(provider.contractProblems)")
        }
    }
}
