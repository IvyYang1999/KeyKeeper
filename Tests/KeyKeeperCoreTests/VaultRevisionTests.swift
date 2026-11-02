import Foundation
import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class VaultRevisionTests: XCTestCase {
    func testSnapshotCodecUsesOneCanonicalMetadataDigest() throws {
        let metadata = MetaFile()
        let revision = VaultRevision(instanceID: UUID(), epoch: 7,
            metadataDigest: try VaultRevision.metadataDigest(for: metadata))
        let original = VaultSnapshotResponse(success: true, metadata: metadata, revision: revision)
        let decoded = try JSONDecoder().decode(VaultSnapshotResponse.self,
            from: JSONEncoder().encode(original))
        XCTAssertEqual(try decoded.validated().revision, revision)
        XCTAssertEqual(try VaultRevision.metadataDigest(for: metadata), revision.metadataDigest)
    }

    func testMalformedMissingAndOldVersionTokensFailClosed() throws {
        let revision = VaultRevision(version: 2, instanceID: UUID(), epoch: 0,
            metadataDigest: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try revision.validate())
        XCTAssertThrowsError(try JSONDecoder().decode(VaultRevision.self,
            from: Data("{\"version\":1}".utf8)))
        XCTAssertThrowsError(try VaultSnapshotResponse(success: true, metadata: MetaFile()).validated())
    }

    func testSnapshotRejectsSecretInlineValue() throws {
        let metadata = MetaFile(credentials: ["fixture": Credential(label: "Synthetic", notes: "", links: [],
            fields: ["token": CredentialField(value: "synthetic-secret", secret: true)],
            security: .standard, created: "2026-11-02", updated: "2026-11-02")])
        XCTAssertThrowsError(try VaultRevision.metadataDigest(for: metadata), "Never produce a hash of an inline secret")
        let revision = VaultRevision(instanceID: UUID(), epoch: 0,
            metadataDigest: String(repeating: "a", count: 64))
        XCTAssertThrowsError(try VaultSnapshotResponse(success: true, metadata: metadata,
            revision: revision).validated())
    }

    func testTokenCodecRejectsUnknownAndMalformedFields() throws {
        let token = VaultRevision(instanceID: UUID(), epoch: 0, metadataDigest: String(repeating: "a", count: 64))
        let encoded = try JSONEncoder().encode(token)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "instanceID", "epoch", "metadataDigest"])
        for (key, value) in [("extra", "ignored"), ("metadataDigest", "not-hex"),
                             ("instanceID", "not-a-uuid"), ("epoch", "not-an-integer")] {
            var changed = object
            changed[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(VaultRevision.self,
                from: JSONSerialization.data(withJSONObject: changed)), key)
        }
    }

    func testCanonicalDigestIsOrderIndependentAndBindsPlainMetadata() throws {
        var first = sampleMetadata()
        first.credentials["second"] = first.credentials["fixture"]
        var second = MetaFile()
        second.credentials["second"] = first.credentials["second"]
        second.credentials["fixture"] = first.credentials["fixture"]
        XCTAssertEqual(try VaultRevision.metadataDigest(for: first), try VaultRevision.metadataDigest(for: second))
        second.credentials["fixture"]?.label = "Changed label"
        XCTAssertNotEqual(try VaultRevision.metadataDigest(for: first), try VaultRevision.metadataDigest(for: second))
    }

    func testSnapshotRejectsWrongDigestAndOversizedMetadata() throws {
        var metadata = sampleMetadata()
        let gate = VaultAccessGate()
        let old = try gate.revision(for: metadata)
        metadata.credentials["fixture"]?.notes = "Changed"
        XCTAssertThrowsError(try VaultSnapshotResponse(success: true, metadata: metadata, revision: old).validated())
        metadata.credentials["fixture"]?.notes = String(repeating: "x", count: VaultSnapshotResponse.maximumEncodedBytes)
        XCTAssertThrowsError(try VaultSnapshotResponse(success: true, metadata: metadata,
            revision: gate.revision(for: metadata)).validated())
        metadata.credentials["fixture"]?.notes = String(repeating: "/", count: VaultSnapshotResponse.maximumEncodedBytes / 2)
        XCTAssertThrowsError(try VaultSnapshotResponse(success: true, metadata: metadata,
            revision: gate.revision(for: metadata)).validated(), "IPC's default encoder escapes slashes")
    }

    func testRestartMetadataChangeAndMissingRevisionAreRejected() throws {
        let metadata = sampleMetadata()
        let gate = VaultAccessGate()
        let original = try gate.revision(for: metadata)
        XCTAssertNoThrow(try gate.validateRevision(original, metadata: metadata, required: true))
        XCTAssertNoThrow(try gate.validateRevision(nil, metadata: metadata, required: false))
        XCTAssertThrowsError(try gate.validateRevision(nil, metadata: metadata, required: true)) {
            XCTAssertEqual($0 as? VaultRevisionError, .required)
        }
        XCTAssertThrowsError(try VaultAccessGate().validateRevision(original, metadata: metadata, required: true)) {
            XCTAssertEqual($0 as? VaultRevisionError, .stale)
        }
        var changed = metadata
        changed.credentials["fixture"]?.label = "Changed"
        XCTAssertThrowsError(try gate.validateRevision(original, metadata: changed, required: true)) {
            XCTAssertEqual($0 as? VaultRevisionError, .stale)
        }
    }

    /// 【曾经的 bug】A secret-only write need not change metadata or its HMAC.
    func testValueOnlyWriteInvalidatesWithoutChangingMetadata() throws {
        let io = FakeKeychainIO()
        let gate = VaultAccessGate()
        let store = KeychainBlobStore(io: io, accessGate: gate)
        let metadata = sampleMetadata()
        try store.save(credentialId: "fixture", fieldName: "token", value: "synthetic-original")
        let original = try gate.revision(for: metadata)
        try store.save(credentialId: "fixture", fieldName: "token", value: "synthetic-rotated")
        let changed = try gate.revision(for: metadata)
        XCTAssertEqual(original.metadataDigest, changed.metadataDigest)
        XCTAssertGreaterThan(changed.epoch, original.epoch)
        XCTAssertThrowsError(try gate.validateRevision(original, metadata: metadata, required: true))
        XCTAssertEqual(try store.retrieve(credentialId: "fixture", fieldName: "token"), "synthetic-rotated")
    }

    func testFailedWriteInvalidatesWithoutPoisoningGateOrRepeatingAdmission() throws {
        var admissions = 0
        let gate = VaultAccessGate { admissions += 1 }
        let io = FakeKeychainIO()
        let store = KeychainBlobStore(io: io, accessGate: gate)
        try store.save(credentialId: "fixture", fieldName: "token", value: "synthetic-original")
        let original = try gate.revision(for: sampleMetadata())
        io.failWrites = true
        let before = admissions
        XCTAssertThrowsError(try store.save(credentialId: "fixture", fieldName: "token", value: "synthetic-new"))
        XCTAssertEqual(admissions, before + 1, "Mutation invalidation performs no separate native admission")
        XCTAssertThrowsError(try gate.validateRevision(original, metadata: sampleMetadata(), required: true))
        XCTAssertEqual(try store.retrieve(credentialId: "fixture", fieldName: "token"), "synthetic-original")

        io.failWrites = false
        let beforeUncertainWrite = try gate.revision(for: sampleMetadata())
        io.afterWrite = { throw VaultRevisionError.unavailable }
        XCTAssertThrowsError(try store.save(credentialId: "fixture", fieldName: "token", value: "synthetic-landed"))
        XCTAssertThrowsError(try gate.validateRevision(beforeUncertainWrite, metadata: sampleMetadata(), required: true))
        XCTAssertEqual(try store.retrieve(credentialId: "fixture", fieldName: "token"), "synthetic-landed",
                       "A write can land and still report failure; its old revision is invalid either way")
    }

    func testEveryValueMutationUsesTheSameInvalidationBoundary() throws {
        let gate = VaultAccessGate()
        let store = KeychainBlobStore(io: FakeKeychainIO(), accessGate: gate)
        let operations: [() throws -> Void] = [
            { try store.save(credentialId: "fixture", fieldName: "one", value: "first") },
            { try store.saveMissing(credentialId: "fixture", fieldName: "two", value: "second") },
            { try store.replaceExisting(credentialId: "fixture", fieldName: "one", value: "third",
                expectedFingerprint: store.valueFingerprint(credentialId: "fixture", fieldName: "one")) },
            { try store.createCredential(credentialId: "new", values: ["token": "fourth"]) },
            { try store.copyValues(fromCredentialId: "fixture", toCredentialId: "copy", fieldMap: [:]) },
            { try store.dropValues(credentialId: "copy", fieldNames: ["one"]) },
            { try store.delete(credentialId: "fixture", fieldName: "two") }
        ]
        for operation in operations {
            let before = try gate.captureEpoch()
            try operation()
            XCTAssertGreaterThan(try gate.captureEpoch(), before)
        }
        let beforeRead = try gate.captureEpoch()
        _ = try store.inspectValueInventory()
        _ = try store.retrieve(credentialId: "fixture", fieldName: "one")
        XCTAssertEqual(try gate.captureEpoch(), beforeRead)
    }

    func testCommitRecoveryAndBlockedAdmissionInvalidateOrRefuse() throws {
        let gate = VaultAccessGate()
        let old = try gate.revision(for: sampleMetadata())
        try gate.withCommit {}
        XCTAssertThrowsError(try gate.validateRevision(old, metadata: sampleMetadata(), required: true))
        let afterCommit = try gate.revision(for: sampleMetadata())
        try gate.withRecovery {}
        XCTAssertThrowsError(try gate.validateRevision(afterCommit, metadata: sampleMetadata(), required: true))
        XCTAssertThrowsError(try gate.withCommit { throw VaultRevisionError.unavailable })
        XCTAssertThrowsError(try gate.revision(for: sampleMetadata()))
        XCTAssertThrowsError(try gate.validateRevision(nil, metadata: sampleMetadata(), required: false))
    }

    private func sampleMetadata() -> MetaFile {
        MetaFile(credentials: ["fixture": Credential(label: "Synthetic", notes: "", links: [],
            fields: ["token": CredentialField(secret: true)], security: .standard,
            created: "2026-11-02", updated: "2026-11-02")])
    }
}
