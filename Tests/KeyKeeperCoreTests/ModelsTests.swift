import XCTest
@testable import KeyKeeperCore

final class ModelsTests: XCTestCase {
    func testCredentialFieldPlain() {
        let field = CredentialField(value: "cli_abc123", secret: false)
        XCTAssertEqual(field.value, "cli_abc123")
        XCTAssertFalse(field.secret)
    }

    func testCredentialFieldSecret() {
        let field = CredentialField(value: nil, secret: true)
        XCTAssertNil(field.value)
        XCTAssertTrue(field.secret)
    }

    func testCredentialCodable() throws {
        let cred = Credential(
            label: "Test API", notes: "some notes",
            links: ["https://example.com"],
            fields: [
                "api_key": CredentialField(value: nil, secret: true),
                "base_url": CredentialField(value: "https://api.example.com", secret: false)
            ],
            security: .standard, created: "2026-02-28", updated: "2026-02-28"
        )
        let data = try JSONEncoder().encode(cred)
        let decoded = try JSONDecoder().decode(Credential.self, from: data)
        XCTAssertEqual(decoded.label, "Test API")
        XCTAssertEqual(decoded.fields["base_url"]?.value, "https://api.example.com")
        XCTAssertTrue(decoded.fields["api_key"]?.secret ?? false)
    }

    func testMetaFileCodable() throws {
        let meta = MetaFile(version: 1, credentials: [
            "test-api": Credential(
                label: "Test", notes: "", links: [],
                fields: ["key": CredentialField(secret: true)],
                security: .standard, created: "2026-02-28", updated: "2026-02-28"
            )
        ])
        let data = try JSONEncoder().encode(meta)
        let decoded = try JSONDecoder().decode(MetaFile.self, from: data)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.credentials.count, 1)
    }
}
