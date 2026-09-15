import XCTest
@testable import KeyKeeperCore

final class ProviderCompatibilityTests: XCTestCase {
    func test新元数据向后兼容且只增加环境别名() throws {
        let plain = ProviderFieldTemplate(name: "token", label: "Token", kind: .secretText, isPrimary: true)
        let encoded = try JSONEncoder().encode(plain)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("aliases"))
        XCTAssertNil(try JSONDecoder().decode(ProviderFieldTemplate.self, from: encoded).aliases)
        var model = try XCTUnwrap(ProviderCatalog.find("zhipu-cn"))
        model.fields[0].aliases = ["PATH"]
        XCTAssertFalse(model.contractProblems.isEmpty)
        model.fields[0].aliases = ["safe-token"]
        XCTAssertTrue(model.contractProblems.isEmpty)
    }

    func test兼容字段是同一字段而不是第二份秘密() throws {
        let provider = try XCTUnwrap(ProviderCatalog.find("zhipu"))
        XCTAssertEqual(provider.id, "zhipu-cn")
        XCTAssertEqual(provider.fieldName, "zai-api-key")
        XCTAssertEqual(provider.field(named: "zhipuai-api-key")?.name, "zai-api-key")
        XCTAssertEqual(provider.fields.filter(\.isPrimary).count, 1)
    }

    func test旧智谱凭据的运行变量不被目录改名重写() {
        let existing = Credential(label: "old", notes: "", links: [],
            fields: ["zhipuai-api-key": .init(secret: true)], security: .strict,
            created: "2026-01-01", updated: "2026-01-01", provider: "zhipu")
        XCTAssertEqual(existing.environmentNames(forField: "zhipuai-api-key"), ["ZHIPUAI_API_KEY"])
        XCTAssertEqual(existing.provider, "zhipu")
    }
}
