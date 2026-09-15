import XCTest
@testable import KeyKeeperCore

final class ProviderRoutingRegressionTests: XCTestCase {
    func testModelScope兼容旧SDK同值变量() throws {
        let t = try XCTUnwrap(ProviderCatalog.find("modelscope-cn"))
        XCTAssertTrue(t.primaryField.environmentNames.contains("MODELSCOPE_API_TOKEN"))
        XCTAssertTrue(t.primaryField.environmentNames.contains("MODELSCOPE_SDK_TOKEN"))
        XCTAssertTrue(t.primaryField.environmentNames.contains("MODELSCOPE_API_KEY"))
        XCTAssertEqual(t.fields.filter(\.isSaveableSecret).count, 1)
    }

    func test每个已公布别名不受大小写影响且不会指向另一模板() {
        for t in ProviderCatalog.all {
            for alias in t.aliases {
                XCTAssertEqual(ProviderCatalog.find(alias)?.id, t.id, alias)
                XCTAssertEqual(ProviderCatalog.find(alias.uppercased())?.id, t.id, alias)
            }
        }
    }
}
