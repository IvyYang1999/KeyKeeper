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
        XCTAssertEqual(ProviderBrowser.results(query: "飞书").map(\.id), ["feishu"])
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
            "All categories", "Choose provider", "Search name or alias", "No matching providers",
            "Try another name or category.", "Clear search", "Open dashboard", "Official management page",
            "{0} providers", "Choose the matching region and plan.", "No provider", "Close provider picker"
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
        XCTAssertNil(ProviderBrowser.movedHighlight(first, by: 1, in: []))
    }

    func test管理后台不是新建表单或另一个产品的控制台() {
        XCTAssertEqual(ProviderBrowser.managementURL(for: "github")?.path, "/settings/personal-access-tokens")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "apns")?.path, "/account/resources/authkeys/list")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "developer-id-installer")?.path, "/account/resources/certificates/list")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "ga4")?.host, "analytics.google.com")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "search-console")?.host, "search.google.com")
        XCTAssertEqual(ProviderBrowser.managementURL(for: "aws-sts")?.host, "console.aws.amazon.com")
    }
}
