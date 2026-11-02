import CryptoKit
import Foundation
import XCTest
@testable import KeyKeeperCore

final class CloudVaultEnvelopeTests: XCTestCase {
    private let context = CloudVaultEnvelopeContext(container: "iCloud.synthetic.test",
        environment: "Development", account: "synthetic-account",
        vaultID: UUID(), keyID: UUID(), revisionID: UUID())

    private func snapshot(_ value: String = "synthetic-value", label: String = "Fixture") throws -> CloudVaultSnapshot {
        try .init(credentials: ["fixture": .init(metadata: Credential(label: label,
            notes: "synthetic-notes", links: [], fields: ["api-key": .init(secret: true)],
            security: .strict, created: "2026-11-02", updated: "2026-11-02"),
            secrets: ["api-key": value])])
    }

    func testSecretAndMetadataRoundTripWithoutPlaintextInEnvelope() throws {
        let key = SymmetricKey(size: .bits256)
        let source = try snapshot()
        let encrypted = try CloudVaultEnvelope.seal(source, key: key, context: context)
        let restored = try CloudVaultEnvelope.open(encrypted, key: key, expectedContext: context)
        XCTAssertEqual(try restored.encoded(), try source.encoded())
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("synthetic-value"))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("synthetic-notes"))
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains(context.account))
    }

    func testWrongKeyFailsClosed() throws {
        let encrypted = try CloudVaultEnvelope.seal(snapshot(), key: SymmetricKey(size: .bits256), context: context)
        XCTAssertThrowsError(try CloudVaultEnvelope.open(encrypted,
            key: SymmetricKey(size: .bits256), expectedContext: context)) {
            XCTAssertEqual($0 as? CloudVaultEnvelopeError, .authenticationFailed)
        }
    }

    private func replacing(container: String? = nil, environment: String? = nil, account: String? = nil,
                           vaultID: UUID? = nil, keyID: UUID? = nil, revisionID: UUID? = nil) -> CloudVaultEnvelopeContext {
        .init(container: container ?? context.container, environment: environment ?? context.environment,
              account: account ?? context.account, vaultID: vaultID ?? context.vaultID,
              keyID: keyID ?? context.keyID, revisionID: revisionID ?? context.revisionID)
    }

    private func rewrite(_ data: Data, _ mutate: (inout [String: Any]) throws -> Void) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private func combined(_ data: Data) throws -> Data {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(Data(base64Encoded: XCTUnwrap(object["sealed"] as? String)))
    }

    func testEveryAccountAndRecordBindingIsAuthenticated() throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try CloudVaultEnvelope.seal(snapshot(), key: key, context: context)
        let mismatches = [replacing(container: "iCloud.synthetic.other"), replacing(environment: "Production"),
            replacing(account: "synthetic-other-account"), replacing(vaultID: UUID()),
            replacing(keyID: UUID()), replacing(revisionID: UUID())]
        for wrongContext in mismatches {
            XCTAssertNotEqual(wrongContext, context)
            XCTAssertThrowsError(try CloudVaultEnvelope.open(encrypted, key: key, expectedContext: wrongContext)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .authenticationFailed)
            }
        }
    }

    func testNonceCiphertextAndAuthenticationTagTamperingAreRejected() throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try CloudVaultEnvelope.seal(snapshot(), key: key, context: context)
        let original = try combined(encrypted)
        for index in [0, 12, original.count - 1] {
            var corrupted = original
            corrupted[index] ^= 1
            let changed = try rewrite(encrypted) { $0["sealed"] = corrupted.base64EncodedString() }
            XCTAssertThrowsError(try CloudVaultEnvelope.open(changed, key: key, expectedContext: context)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .authenticationFailed)
            }
        }
    }

    func testRepeatedSealsHaveFreshStandardNonces() throws {
        let key = SymmetricKey(size: .bits256)
        let source = try snapshot()
        let first = try combined(CloudVaultEnvelope.seal(source, key: key, context: context))
        let second = try combined(CloudVaultEnvelope.seal(source, key: key, context: context))
        XCTAssertNotEqual(first.prefix(12), second.prefix(12))
        XCTAssertEqual(first.count, try source.encoded().count + 12 + 16)
        XCTAssertEqual(second.count, first.count)
    }

    func testIndependentSnapshotsAndRevisionsRoundTrip() throws {
        let key = SymmetricKey(size: .bits256)
        let sources = [try CloudVaultSnapshot(credentials: [:]), try snapshot("假数据-🗝️", label: "Unicode fixture"),
                       try snapshot("synthetic-rotated", label: "Renamed fixture")]
        for source in sources {
            let revisionContext = replacing(revisionID: UUID())
            let encrypted = try CloudVaultEnvelope.seal(source, key: key, context: revisionContext)
            XCTAssertEqual(try CloudVaultEnvelope.open(encrypted, key: key,
                expectedContext: revisionContext).encoded(), try source.encoded())
        }
    }

    func testUnknownSchemaUnknownFieldsAndNoncanonicalEncodingFailClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try CloudVaultEnvelope.seal(snapshot(), key: key, context: context)
        let future = try rewrite(encrypted) { $0["version"] = 99 }
        XCTAssertThrowsError(try CloudVaultEnvelope.open(future, key: key, expectedContext: context)) {
            XCTAssertEqual($0 as? CloudVaultEnvelopeError, .unsupportedVersion)
        }
        let unknown = try rewrite(encrypted) { $0["futureRequiredField"] = "synthetic" }
        let duplicate = Data(String(decoding: encrypted, as: UTF8.self)
            .replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1").utf8)
        XCTAssertNotEqual(duplicate, encrypted)
        for malformed in [Data("not-json".utf8), Data(), unknown, encrypted + Data(" ".utf8), duplicate] {
            XCTAssertThrowsError(try CloudVaultEnvelope.open(malformed, key: key, expectedContext: context)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidEnvelope)
            }
        }
    }

    func testMaximumSnapshotRoundTripsAndOneMoreByteCannotBeSealed() throws {
        let key = SymmetricKey(size: .bits256)
        let overhead = try snapshot("").encoded().count
        let value = String(repeating: "x", count: CloudVaultSnapshot.maximumBytes - overhead)
        let source = try snapshot(value)
        XCTAssertEqual(try source.encoded().count, CloudVaultSnapshot.maximumBytes)
        let encrypted = try CloudVaultEnvelope.seal(source, key: key, context: context)
        XCTAssertLessThanOrEqual(encrypted.count, CloudVaultEnvelope.maximumBytes)
        XCTAssertEqual(try CloudVaultEnvelope.open(encrypted, key: key, expectedContext: context).encoded(),
                       try source.encoded())
        XCTAssertThrowsError(try CloudVaultEnvelope.seal(snapshot(value + "x"), key: key, context: context)) {
            XCTAssertEqual($0 as? CloudVaultError, .tooLarge)
        }
    }

    func testOversizedEnvelopeAndCombinedBoxAndTruncatedBoxFailClosed() throws {
        let key = SymmetricKey(size: .bits256)
        let encrypted = try CloudVaultEnvelope.seal(snapshot(), key: key, context: context)
        let oversizedBox = try rewrite(encrypted) {
            $0["sealed"] = Data(repeating: 0, count: CloudVaultSnapshot.maximumBytes + 29).base64EncodedString()
        }
        XCTAssertLessThanOrEqual(oversizedBox.count, CloudVaultEnvelope.maximumBytes)
        for oversized in [Data(repeating: 0, count: CloudVaultEnvelope.maximumBytes + 1), oversizedBox] {
            XCTAssertThrowsError(try CloudVaultEnvelope.open(oversized, key: key, expectedContext: context)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .tooLarge)
            }
        }
        let truncated = try rewrite(encrypted) { $0["sealed"] = Data(repeating: 0, count: 27).base64EncodedString() }
        XCTAssertThrowsError(try CloudVaultEnvelope.open(truncated, key: key, expectedContext: context)) {
            XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidEnvelope)
        }
    }

    func testContextByteLimitsAndEnvironmentAreValidatedOnSealAndOpen() throws {
        let key = SymmetricKey(size: .bits256)
        let source = try snapshot()
        let encrypted = try CloudVaultEnvelope.seal(source, key: key, context: context)
        let invalid = [replacing(account: ""), replacing(container: ""), replacing(environment: "staging"),
                       replacing(account: String(repeating: "é", count: 513)),
                       replacing(container: String(repeating: "x", count: 1025))]
        for invalidContext in invalid {
            XCTAssertThrowsError(try CloudVaultEnvelope.seal(source, key: key, context: invalidContext)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidContext)
            }
            XCTAssertThrowsError(try CloudVaultEnvelope.open(encrypted, key: key, expectedContext: invalidContext)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidContext)
            }
        }
        let maximum = replacing(container: String(repeating: "x", count: 1024),
                                environment: "Production", account: String(repeating: "é", count: 512))
        let maximumEnvelope = try CloudVaultEnvelope.seal(source, key: key, context: maximum)
        XCTAssertEqual(try CloudVaultEnvelope.open(maximumEnvelope, key: key, expectedContext: maximum).encoded(),
                       try source.encoded())
    }

    func testOnlyAES256KeysAreAccepted() throws {
        let source = try snapshot()
        let encrypted = try CloudVaultEnvelope.seal(source, key: SymmetricKey(size: .bits256), context: context)
        for key in [SymmetricKey(size: .bits128), SymmetricKey(size: .bits192)] {
            XCTAssertThrowsError(try CloudVaultEnvelope.seal(source, key: key, context: context)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidKey)
            }
            XCTAssertThrowsError(try CloudVaultEnvelope.open(encrypted, key: key, expectedContext: context)) {
                XCTAssertEqual($0 as? CloudVaultEnvelopeError, .invalidKey)
            }
        }
    }

    func testContextAndErrorsDoNotDiscloseAccountOrValuesInDescriptions() {
        let errors: [CloudVaultEnvelopeError] = [.invalidEnvelope, .unsupportedVersion, .tooLarge,
                                                .invalidContext, .invalidKey, .authenticationFailed]
        let descriptions = [String(describing: context), String(reflecting: context)] + errors.flatMap {
            [String(describing: $0), String(reflecting: $0), $0.localizedDescription]
        }
        for description in descriptions {
            XCTAssertFalse(description.contains(context.account))
            XCTAssertFalse(description.contains(context.container))
            XCTAssertFalse(description.contains("synthetic-value"))
        }
    }
}
