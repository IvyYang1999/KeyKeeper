import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class ProviderBrowserTests: XCTestCase {
    func test每个模板恰好属于一个明确分类() {
        let ids = ProviderBrowser.groups.values.flatMap { $0 }
        XCTAssertEqual(Set(ids), Set(ProviderCatalog.all.map(\.id)))
        XCTAssertEqual(ids.count, Set(ids).count)
        XCTAssertEqual(ProviderBrowser.results(query: "").count, 113)
    }

    func test搜索名称中文旧别名和多关键词不混淆地区套餐() {
        XCTAssertEqual(ProviderBrowser.results(query: "  cHaTgPt  ").map(\.id), ["openai"])
        XCTAssertEqual(ProviderBrowser.results(query: "飞书").map(\.id), ["feishu", "lark"])
        XCTAssertEqual(ProviderBrowser.results(query: "zhipu coding").map(\.id), ["zhipu-cn-coding"])
        XCTAssertEqual(ProviderBrowser.results(query: "mimo europe").map(\.id), ["xiaomi-mimo-token-plan-eu"])
        XCTAssertEqual(ProviderBrowser.results(query: "does-not-exist"), [])
        XCTAssertTrue(ProviderBrowser.results(query: "stripe", category: .models).isEmpty)
        XCTAssertEqual(ProviderBrowser.results(query: "", category: .payments).map(\.id), ["stripe"])
    }

    func test管理入口只用内置HTTPS且旧绑定仍能解析() throws {
        for template in ProviderCatalog.all {
            let url = try XCTUnwrap(ProviderBrowser.managementURL(for: template.id), template.id)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertNotNil(url.host)
            XCTAssertNil(url.user)
            XCTAssertNil(url.password)
        }
        XCTAssertEqual(ProviderBrowser.managementURL(for: "zhipu"), ProviderBrowser.managementURL(for: "zhipu-cn"))
        XCTAssertEqual(ProviderBrowser.managementURL(for: "resend")?.absoluteString, "https://resend.com/api-keys")
        XCTAssertNil(ProviderBrowser.managementURL(for: nil))
        XCTAssertNil(ProviderBrowser.managementURL(for: "https://example.com/"))
        XCTAssertNil(ProviderBrowser.safeWebURL("file:///tmp/example"))
        XCTAssertNil(ProviderBrowser.safeWebURL("http://example.com"))
        var fixture = URLComponents(string: "https://example.com")!
        fixture.user = "synthetic-user"
        XCTAssertNil(ProviderBrowser.safeWebURL(fixture.string!))
    }

    func test分类与新界面文案有中文且占位符一致() {
        let keys = ProviderCategory.allCases.map(\.rawValue) + [
            "All categories", "Choose provider", "Search providers, e.g. OpenAI, Stripe", "No matching providers",
            "Try another name or category.", "Unbind provider", "Create the key at {0}", "Manage at {0}",
            "{0} options", "Pick one and the fields fill in; you can also type them below."
        ]
        for key in keys {
            let translated = AppL10n.render(key, language: "zh-Hans")
            XCTAssertNotEqual(translated, key, key)
            XCTAssertEqual(AppL10n.placeholders(in: key), AppL10n.placeholders(in: translated))
        }
    }

    func test方向键按当前结果移动且不越界空结果不选中() {
        let rows = ProviderBrowser.results(query: "app store connect", category: .apple)
        let first = rows[0].id
        let second = rows[1].id
        XCTAssertEqual(ProviderBrowser.movedHighlight(first, by: 1, in: rows), second)
        XCTAssertEqual(ProviderBrowser.movedHighlight(first, by: -1, in: rows), first)
        XCTAssertEqual(ProviderBrowser.movedHighlight(rows.last!.id, by: 1, in: rows), rows.last!.id)
        XCTAssertNil(ProviderBrowser.movedHighlight(first, by: 1, in: [ProviderTemplate]()))
    }

    func test管理后台不是新建表单或另一个产品的控制台() {
        XCTAssertEqual(ProviderBrowser.managementURL(for: "github")?.path, "/settings/personal-access-tokens")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "apns")?.path, "/account/resources/authkeys/list")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "developer-id-installer")?.path, "/account/resources/certificates/list")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "ga4")?.host, "analytics.google.com")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "search-console")?.host, "search.google.com")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "aws-sts")?.host, "console.aws.amazon.com")
    }

    func test每个模板恰好属于一个品牌且品牌表没有拼错的成员() {
        let ids = ProviderBrowser.families.flatMap { $0.members.map(\.id) }
        XCTAssertEqual(Set(ids), Set(ProviderCatalog.all.map(\.id)))
        XCTAssertEqual(ids.count, Set(ids).count)
        for row in ProviderBrowser.familyTable {
            XCTAssertEqual(row.members.count, ProviderBrowser.families.first { $0.id == row.id }?.members.count, row.id)
            XCTAssertGreaterThan(row.members.count, 1, "\(row.id) is not a family")
        }
        XCTAssertLessThan(ProviderBrowser.families.count, 80)
        XCTAssertEqual(ProviderBrowser.family(containing: "alibaba-bailian-hk")?.id, "alibaba-bailian")
        XCTAssertEqual(ProviderBrowser.family(containing: "stripe")?.name, "Stripe")
    }

    func test变体标签去掉品牌前缀并统一括号() throws {
        func label(_ id: String) throws -> String {
            let family = try XCTUnwrap(ProviderBrowser.family(containing: id))
            return family.variantLabel(try XCTUnwrap(ProviderCatalog.find(id)))
        }
        XCTAssertEqual(try label("alibaba-bailian-hk"), "按量 (中国香港)")
        XCTAssertEqual(try label("kimi"), "Open Platform (China)")
        XCTAssertEqual(try label("zai-global"), "API (Global)")
        XCTAssertEqual(try label("zhipu-cn"), "开放平台 (中国)")
        XCTAssertEqual(try label("aws-sts"), "STS · Temporary credentials")
        XCTAssertEqual(try label("dockerhub-oat"), "Organization access token")
        XCTAssertEqual(try label("lark"), "(Global)")
        XCTAssertEqual(ProviderBrowser.variantLabel("Stripe", stripping: ["Stripe"]), "Stripe")
        XCTAssertEqual(ProviderBrowser.environmentSummary(try XCTUnwrap(ProviderCatalog.find("openai"))), "OPENAI_API_KEY")
        XCTAssertEqual(ProviderBrowser.environmentSummary(try XCTUnwrap(ProviderCatalog.find("vercel"))), "VERCEL_TOKEN +2")
    }

    func test搜索按品牌分行单个命中直接给模板行多个命中自动展开() throws {
        let one = ProviderBrowser.rows(query: "mimo europe", expanded: [])
        XCTAssertEqual(one.count, 1)
        guard case .template(let template, let family, let nested, let variant) = try XCTUnwrap(one.first) else { return XCTFail() }
        XCTAssertEqual(template.id, "xiaomi-mimo-token-plan-eu")
        XCTAssertEqual(family.id, "xiaomi-mimo")
        XCTAssertFalse(nested)
        XCTAssertEqual(variant, "Token Plan (欧洲)")

        let many = ProviderBrowser.rows(query: "mimo", expanded: [])
        XCTAssertEqual(many.map(\.id), ["family:xiaomi-mimo", "template:xiaomi-mimo-payg", "template:xiaomi-mimo-token-plan-cn",
                                         "template:xiaomi-mimo-token-plan-sg", "template:xiaomi-mimo-token-plan-eu"])
        guard case .family(_, _, let expanded) = try XCTUnwrap(many.first) else { return XCTFail() }
        XCTAssertTrue(expanded)

        let collapsed = ProviderBrowser.rows(query: "", expanded: [])
        XCTAssertEqual(collapsed.count, ProviderBrowser.families.count)
        XCTAssertFalse(collapsed.contains { $0.id == "template:minimax-global" })
        let open = ProviderBrowser.rows(query: "", expanded: ["minimax"])
        XCTAssertEqual(open.count, ProviderBrowser.families.count + 4)
        XCTAssertEqual(ProviderBrowser.rows(query: "", category: .payments, expanded: []).map(\.id), ["template:stripe"])
        XCTAssertEqual(ProviderBrowser.movedHighlight("family:xiaomi-mimo", by: 1, in: many), "template:xiaomi-mimo-payg")
    }

    func test取钥入口是模板的创建页而管理入口可以不同() {
        XCTAssertEqual(ProviderBrowser.createURL(for: "github")?.path, "/settings/personal-access-tokens/new")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "github")?.path, "/settings/personal-access-tokens")
        XCTAssertNil(ProviderBrowser.createURL(for: nil))
        XCTAssertNil(ProviderBrowser.createURL(for: "not-a-provider"))
    }
}
