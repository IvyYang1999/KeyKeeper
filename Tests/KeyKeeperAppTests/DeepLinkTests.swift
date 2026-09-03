import XCTest
@testable import KeyKeeperApp

final class DeepLinkTests: XCTestCase {
    func test解析新增凭据深链() throws {
        let url = try XCTUnwrap(URL(string: "keykeeper://add?label=Open%20AI&fields=api-key,%20org-id&notes=billing"))
        XCTAssertEqual(
            DeepLink.parse(url),
            .addCredential(label: "Open AI", fields: ["api-key", "org-id"], notes: "billing")
        )
    }

    func test缺省参数与空字段() throws {
        XCTAssertEqual(
            DeepLink.parse(try XCTUnwrap(URL(string: "keykeeper://add"))),
            .addCredential(label: nil, fields: [], notes: nil)
        )
        XCTAssertEqual(
            DeepLink.parse(try XCTUnwrap(URL(string: "keykeeper://add?label=&fields=,"))),
            .addCredential(label: nil, fields: [], notes: nil)
        )
    }

    func test其它scheme或host不解析() throws {
        XCTAssertNil(DeepLink.parse(try XCTUnwrap(URL(string: "https://add?label=x"))))
        XCTAssertNil(DeepLink.parse(try XCTUnwrap(URL(string: "keykeeper://delete?id=x"))))
    }

    func test生成的链接能被自己解析() throws {
        let url = try XCTUnwrap(DeepLink.addURL(label: "Feishu Bot", fields: ["app-id", "app-secret"]))
        XCTAssertEqual(url.scheme, "keykeeper")
        XCTAssertEqual(
            DeepLink.parse(url),
            .addCredential(label: "Feishu Bot", fields: ["app-id", "app-secret"], notes: nil)
        )
    }
}
