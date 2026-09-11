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
}
