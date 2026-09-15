import XCTest
@testable import KeyKeeperCore

final class GatewayModelProviderTests: XCTestCase {
    func testAtlasCloudOrdinaryAndCodingUseSeparateCredentialContracts() throws {
        let ordinary = try XCTUnwrap(GatewayModelProviderCatalog.all.first { $0.id == "atlascloud" })
        let coding = try XCTUnwrap(GatewayModelProviderCatalog.all.first { $0.id == "atlascloud-coding-plan" })

        XCTAssertEqual(ordinary.fieldName, "atlascloud-api-key")
        XCTAssertEqual(ordinary.fields.first?.environmentNames, ["ATLASCLOUD_API_KEY"])
        XCTAssertTrue(ordinary.shownOnce)
        XCTAssertEqual(ordinary.endpoints?.first,
                       ProviderEndpoint("OpenAI compatible", "https://api.atlascloud.ai/v1"))

        XCTAssertEqual(coding.fieldName, "atlascloud-coding-api-key")
        XCTAssertTrue(coding.aliases.contains("atlascloud-coding"))
        XCTAssertEqual(coding.fields.first?.environmentNames,
                       ["ATLASCLOUD_CODING_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertFalse(coding.shownOnce)
        XCTAssertEqual(coding.endpoints, [
            ProviderEndpoint("OpenAI compatible", "https://api.atlascloud.ai/v1"),
            ProviderEndpoint("Anthropic Messages", "https://api.atlascloud.ai"),
        ])
        XCTAssertNil(ordinary.validation)
        XCTAssertNil(coding.validation)
    }

    func testAuditedGatewaySetIsCompleteAndNeverProbesSavedSecrets() {
        XCTAssertEqual(Set(GatewayModelProviderCatalog.all.map(\.id)), Set([
            "atlascloud", "atlascloud-coding-plan",
            "compshare-modelverse-cn", "compshare-modelverse-global", "compshare-agent-plan",
            "ccsub", "micu-claude", "micu-codex", "rightcode-codex", "cubence",
            "crazyrouter", "dmxapi-cn", "dmxapi-global", "dmxapi-ssvip",
            "aihubmix", "amux", "cherryin",
        ]))
        XCTAssertTrue(GatewayModelProviderCatalog.all.allSatisfy { $0.validation == nil })
        XCTAssertTrue(GatewayModelProviderCatalog.all.allSatisfy { !($0.sources ?? []).isEmpty })
    }

    func testSeparatePlansAndRealmsCannotBeCollapsedIntoOneTemplate() throws {
        let agentPlan = try provider("compshare-agent-plan")
        XCTAssertEqual(agentPlan.fieldName, "compshare-agent-plan-api-key")
        XCTAssertEqual(agentPlan.endpoints, [
            ProviderEndpoint("OpenAI compatible", "https://cp.compshare.cn/v1"),
            ProviderEndpoint("Anthropic Messages", "https://cp.compshare.cn"),
        ])

        let ordinaryCN = try provider("compshare-modelverse-cn")
        let ordinaryGlobal = try provider("compshare-modelverse-global")
        XCTAssertEqual(ordinaryCN.fieldName, "compshare-api-key")
        XCTAssertEqual(ordinaryCN.endpoints?.first?.baseURL, "https://api.modelverse.cn/v1")
        XCTAssertEqual(ordinaryGlobal.endpoints?.first?.baseURL, "https://api.umodelverse.ai/v1")

        let dmxRealms = try ["dmxapi-cn", "dmxapi-global", "dmxapi-ssvip"].map(provider)
        XCTAssertEqual(Set(dmxRealms.compactMap { $0.endpoints?.first?.baseURL }), Set([
            "https://www.dmxapi.cn/v1", "https://www.dmxapi.com/v1", "https://ssvip.dmxapi.com/v1",
        ]))
        XCTAssertTrue(dmxRealms.allSatisfy { $0.fieldName == "dmx-api-key" })
    }

    func testOfficialClientAliasesMapToTheSameSavedSecret() throws {
        XCTAssertEqual(try provider("ccsub").fields.first?.environmentNames,
                       ["CCSUB_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(try provider("micu-claude").fields.first?.environmentNames,
                       ["MICU_API_KEY", "ANTHROPIC_API_KEY"])
        XCTAssertEqual(try provider("micu-codex").fields.first?.environmentNames,
                       ["MICU_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(try provider("rightcode-codex").fields.first?.environmentNames,
                       ["RIGHTCODE_API_KEY", "OPENAI_API_KEY"])
        XCTAssertEqual(try provider("cubence").fields.first?.environmentNames,
                       ["CUBENCE_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
        XCTAssertEqual(try provider("cherryin").fields.first?.environmentNames,
                       ["CHERRYIN_API_KEY", "ANTHROPIC_AUTH_TOKEN"])
    }

    func testDocumentedEndpointAndLifecycleExceptionsArePreserved() throws {
        let cubence = try provider("cubence")
        XCTAssertEqual(cubence.createURL, "https://cubence.com/dashboard/keys")
        XCTAssertEqual(cubence.endpoints?.first,
                       ProviderEndpoint("OpenAI compatible", "https://api.cubence.com/v1"))

        let crazyrouter = try provider("crazyrouter")
        XCTAssertEqual(crazyrouter.prefixes, ["sk-"])
        XCTAssertEqual(crazyrouter.endpoints, [
            ProviderEndpoint("OpenAI compatible", "https://api.crazyrouter.com/v1", region: "International"),
            ProviderEndpoint("Anthropic Messages", "https://api.crazyrouter.com", region: "International"),
            ProviderEndpoint("OpenAI compatible", "https://cn.crazyrouter.com/v1", region: "East Asia"),
            ProviderEndpoint("Anthropic Messages", "https://cn.crazyrouter.com", region: "East Asia"),
        ])

        let amux = try provider("amux")
        XCTAssertFalse(amux.shownOnce)
        XCTAssertEqual(amux.createURL, "https://amux.ai/keys")
        XCTAssertEqual(amux.fields.first?.environmentNames, ["AMUX_API_KEY"])
        XCTAssertEqual(amux.endpoints?.first?.baseURL, "https://gateway.amux.ai/v1")
    }

    private func provider(_ id: String) throws -> ProviderTemplate {
        try XCTUnwrap(GatewayModelProviderCatalog.all.first { $0.id == id }, "missing \(id)")
    }
}
