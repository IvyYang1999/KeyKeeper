import XCTest
@testable import KeyKeeperCore

final class ModelsTests: XCTestCase {
    func test曾经的BugStrict凭据读取等待完整交互授权窗口() {
        XCTAssertEqual(
            KeychainReadTimeoutPolicy.timeout(for: .strict),
            IPCConstants.authTimeout
        )
        XCTAssertEqual(
            KeychainReadTimeoutPolicy.timeout(for: .standard),
            IPCConstants.keychainTimeout
        )
    }

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

    func testPersistentFieldValidationRejectsURLAndEnforcesPublicShapeFragments() throws {
        let validation = try CredentialFieldValidation(
            rejectURL: true,
            prefixes: ["GOCSPX-"],
            suffixes: [".apps.googleusercontent.com"]
        ).validated()

        XCTAssertNotNil(validation.problem(for: "http://127.0.0.1:49152/#receiver"))
        XCTAssertNotNil(validation.problem(for: "wrong.apps.googleusercontent.com"))
        XCTAssertNotNil(validation.problem(for: "GOCSPX-synthetic"))
        XCTAssertNotNil(validation.problem(for: "GOCSPX-synthetic.apps.googleusercontent.com\n"),
                        "suffix rules apply to the exact stored value, not a silently trimmed copy")
        XCTAssertNil(validation.problem(for: "GOCSPX-synthetic.apps.googleusercontent.com"))
        XCTAssertThrowsError(try CredentialFieldValidation(prefixes: ["contains a space"]).validated())
        XCTAssertThrowsError(try CredentialFieldValidation(suffixes: [String(repeating: "x", count: 65)]).validated())
    }

    func testCredentialFieldValidationIsBackwardCompatibleAndRoundTrips() throws {
        let old = Data(#"{"secret":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CredentialField.self, from: old).validation)

        let field = CredentialField(secret: true, validation: .init(
            rejectURL: true, prefixes: ["sk-"], suffixes: [".example"]
        ))
        let decoded = try JSONDecoder().decode(CredentialField.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(decoded.validation, field.validation)
    }

    func testPersistentValidationCanOnlyTightenNeverBroaden() throws {
        let existing = CredentialFieldValidation(
            rejectURL: true, prefixes: ["sk-"], suffixes: [".example"])
        let narrower = try existing.tightening(with: .init(
            prefixes: ["sk-project-"], suffixes: [".api.example"])
        )
        XCTAssertEqual(narrower.prefixes, ["sk-project-"])
        XCTAssertEqual(narrower.suffixes, [".api.example"])
        XCTAssertTrue(narrower.rejectURL)
        XCTAssertThrowsError(try existing.tightening(with: .init(prefixes: ["AKIA"])),
                             "adding an unrelated alternative would silently broaden the field")
        XCTAssertThrowsError(try existing.tightening(with: .init(suffixes: [".invalid"])))
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
