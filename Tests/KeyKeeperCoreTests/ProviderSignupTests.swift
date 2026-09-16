import XCTest
@testable import KeyKeeperCore

final class ProviderSignupTests: XCTestCase {
    func test注册链接是可选字段旧JSON照样解码新JSON带双方收益() throws {
        let plain = try JSONDecoder().decode(ProviderTemplate.self, from: try JSONEncoder().encode(ProviderCatalog.all[0]))
        XCTAssertNil(plain.signup)
        var template = ProviderCatalog.all[0]
        template.signup = ProviderSignup(url: "https://example.com/?ref=keykeeper", whatYouGet: "20M tokens", whatWeGet: "$5 in credits after you spend $10", code: "KK1")
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(ProviderTemplate.self, from: data)
        XCTAssertEqual(decoded.signup, template.signup)
        XCTAssertEqual(decoded.signup?.whatYouGet, "20M tokens")
        XCTAssertEqual(decoded.signup?.whatWeGet, "$5 in credits after you spend $10")
        XCTAssertEqual(decoded.signup?.code, "KK1")
        XCTAssertTrue(template.contractProblems.isEmpty)
        template.signup = ProviderSignup(url: "http://example.com", whatWeGet: " ")
        XCTAssertEqual(template.contractProblems, ["signup url must use HTTPS", "signup must say what KeyKeeper gets"])
    }

    func test硅基流动建Key和注册是两个入口且全球站不误用国内推荐() throws {
        let china = try XCTUnwrap(ProviderCatalog.find("siliconflow"))
        let signup = try XCTUnwrap(china.signup)
        XCTAssertEqual(china.createURL, "https://cloud.siliconflow.cn/account/ak")
        XCTAssertEqual(signup.url, "https://cloud.siliconflow.cn/i/rYSj1fxJ")
        XCTAssertNotEqual(signup.url, china.createURL)
        XCTAssertEqual(signup.code, "rYSj1fxJ")
        XCTAssertFalse(signup.whatYouGet?.isEmpty ?? true)
        XCTAssertFalse(signup.whatWeGet.isEmpty)
        XCTAssertNil(ProviderCatalog.find("siliconflow-global")?.signup)
    }

}
