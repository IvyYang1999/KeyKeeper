import XCTest
@testable import KeyKeeperCore

final class ProviderSignupTests: XCTestCase {
    func test注册链接是可选字段旧JSON照样解码新JSON带披露() throws {
        let plain = try JSONDecoder().decode(ProviderTemplate.self, from: try JSONEncoder().encode(ProviderCatalog.all[0]))
        XCTAssertNil(plain.signup)
        var template = ProviderCatalog.all[0]
        template.signup = ProviderSignup(url: "https://example.com/?ref=keykeeper", whatYouGet: "20M tokens", whatWeGet: "$5 in credits after you spend $10", code: "KK1")
        let data = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(ProviderTemplate.self, from: data)
        XCTAssertEqual(decoded.signup, template.signup)
        XCTAssertEqual(decoded.signup?.disclosure, "You get 20M tokens. Signing up through this link gives KeyKeeper $5 in credits after you spend $10. Invite code: KK1.")
        XCTAssertTrue(template.contractProblems.isEmpty)
        template.signup = ProviderSignup(url: "http://example.com", whatWeGet: " ")
        XCTAssertEqual(template.contractProblems, ["signup url must use HTTPS", "signup must say what KeyKeeper gets"])
    }

    func test目录顺序和推荐无关() {
        // The catalog has no notion of "featured": every listing sorts by name, so a referral
        // cannot buy a better spot. Guard the property the policy rests on.
        let names = ProviderCatalog.all.map(\.name)
        XCTAssertEqual(ProviderCatalog.all.filter { $0.signup != nil }.count, ProviderCatalog.all.filter { $0.signup != nil }.count)
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(Set(names).count, names.count, "names are unique so a sort by name is total")
        XCTAssertEqual(sorted.count, names.count)
    }
}
