import XCTest
@testable import KeyKeeperCore

final class CredentialFileTests: XCTestCase {
    static let document = "{\n  \"type\": \"service_account\", \"client_email\": \"fixture@example.invalid\", \"private_key\": \"synthetic-not-a-real-private-key\"\n}\n"

    func testServiceAccountShapePreservesBytesAndErrorsAreConstant() throws {
        let value = try CredentialFileFormat.serviceAccountJSON.validate(Data(Self.document.utf8))
        XCTAssertEqual(value, Self.document)
        for invalid in ["{}", "[]", "not-json", "{\"type\":\"other\"}", String(repeating: "x", count: 65_537)] {
            XCTAssertThrowsError(try CredentialFileFormat.serviceAccountJSON.validate(Data(invalid.utf8))) { error in
                XCTAssertEqual(error as? ClipboardSaveError, .invalidFile)
            }
        }
    }

    func testOldFieldDecodesWithoutFormatAndFileRoundTrips() throws {
        let old = try JSONDecoder().decode(CredentialField.self, from: Data("{\"secret\":true}".utf8))
        XCTAssertNil(old.fileFormat)
        let field = CredentialField(secret: true, fileFormat: .serviceAccountJSON)
        let encoded = try JSONEncoder().encode(field)
        XCTAssertEqual(try JSONDecoder().decode(CredentialField.self, from: encoded).fileFormat, .serviceAccountJSON)
        XCTAssertNil(field.value)
    }

    /// yyt 2026-09-11：服务账号文件界面上什么都看不到，以为是 bug。只取出不保密的
    /// client_email 和 project_id 给界面看，私钥不进摘要。
    func test服务账号摘要只取邮箱和项目编号() {
        let json = #"{"type":"service_account","project_id":"ga4-demo","client_email":"bot@ga4-demo.iam.gserviceaccount.com","private_key":"-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----\n"}"#
        let summary = ServiceAccountSummary.parse(json)
        XCTAssertEqual(summary?.clientEmail, "bot@ga4-demo.iam.gserviceaccount.com")
        XCTAssertEqual(summary?.projectId, "ga4-demo")
        XCTAssertNil(ServiceAccountSummary.parse("not-json"))
        XCTAssertNil(ServiceAccountSummary.parse(#"{"type":"service_account","project_id":"x"}"#), "没有邮箱就不算服务账号")
        XCTAssertNil(ServiceAccountSummary.parse(#"{"type":"service_account","client_email":"a@b"}"#)?.projectId)
    }
}
