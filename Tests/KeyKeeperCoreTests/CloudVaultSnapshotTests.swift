import Foundation
import XCTest
@testable import KeyKeeperCore

final class CloudVaultSnapshotTests: XCTestCase {
    private func entry(_ value: String = "synthetic", label: String = "Fixture") -> CloudCredentialBundle {
        .init(metadata: Credential(label: label, notes: "", links: [],
            fields: ["api-key": .init(secret: true)], security: .strict,
            created: "2026-10-29", updated: "2026-10-29"),
            secrets: ["api-key": value])
    }

    private func snapshot(_ entries: [String: CloudCredentialBundle]) throws -> CloudVaultSnapshot {
        try .init(credentials: entries)
    }

    func testSecretAndMetadataRoundTripAsOneBundle() throws {
        let source = try snapshot(["fixture": entry()])
        let encoded = try source.encoded()
        let restored = try CloudVaultSnapshot.decode(encoded)
        XCTAssertEqual(restored.credentials["fixture"]?.metadata.label, "Fixture")
        XCTAssertEqual(restored.credentials["fixture"]?.secrets["api-key"], "synthetic")
    }

    func testMissingAndOrphanSecretsAreNotAnEmptySnapshot() throws {
        var incomplete = entry()
        incomplete.secrets = [:]
        XCTAssertThrowsError(try snapshot(["fixture": incomplete]))
        var orphan = entry()
        orphan.secrets["not-in-metadata"] = "synthetic-extra"
        XCTAssertThrowsError(try snapshot(["fixture": orphan]))
        var secretInMetadata = entry()
        secretInMetadata.metadata.fields["api-key"]?.value = "synthetic-leak"
        XCTAssertThrowsError(try snapshot(["fixture": secretInMetadata]))
    }

    func testIndependentEditsMergeWithoutOverwritingEitherMac() throws {
        let base = try snapshot(["a": entry(), "b": entry()])
        let local = try snapshot(["a": entry("synthetic-local"), "b": entry()])
        let remote = try snapshot(["a": entry(), "b": entry("synthetic-remote")])
        let merged = try CloudVaultMerge.merge(base: base, local: local, remote: remote).resolved()
        XCTAssertEqual(merged.credentials["a"]?.secrets["api-key"], "synthetic-local")
        XCTAssertEqual(merged.credentials["b"]?.secrets["api-key"], "synthetic-remote")
    }

    func testConcurrentEditAndDeleteConflictInBothOrders() throws {
        let base = try snapshot(["a": entry()])
        let changed = try snapshot(["a": entry("synthetic-new")])
        let deleted = try snapshot([:])
        for (left, right) in [(changed, deleted), (deleted, changed)] {
            let result = try CloudVaultMerge.merge(base: base, local: left, remote: right)
            XCTAssertEqual(result.conflictingIDs, ["a"])
            XCTAssertThrowsError(try result.resolved())
        }
    }

    func testObservedDeletionDoesNotResurrectFromUnchangedOtherMac() throws {
        let base = try snapshot(["a": entry()])
        let empty = try snapshot([:])
        for (left, right) in [(base, empty), (empty, base)] {
            let result = try CloudVaultMerge.merge(base: base, local: left, remote: right).resolved()
            XCTAssertTrue(result.credentials.isEmpty)
        }
    }

    func testFirstPairingNeverInterpretsAbsentLocalDataAsDeletion() throws {
        let remote = try snapshot(["a": entry()])
        let merged = try CloudVaultMerge.merge(base: nil, local: snapshot([:]), remote: remote).resolved()
        XCTAssertNotNil(merged.credentials["a"])
        let conflict = try CloudVaultMerge.merge(base: nil,
            local: snapshot(["a": entry("synthetic-different")]), remote: remote)
        XCTAssertEqual(conflict.conflictingIDs, ["a"])
    }

    func testUnknownSchemaCorruptAndOversizedPayloadFailClosed() throws {
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(Data("not-json".utf8)))
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(Data(#"{"version":99,"credentials":{}}"#.utf8)))
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(Data(repeating: 0, count: CloudVaultSnapshot.maximumBytes + 1)))
    }

    func testCanonicalCodecDoesNotSilentlyDropUnknownMetadataOrGrants() throws {
        let source = try snapshot(["fixture": entry()])
        let data = try source.encoded()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "credentials"])
        object["approvals"] = ["synthetic-grant"]
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])))
        object.removeValue(forKey: "approvals")
        var credentials = try XCTUnwrap(object["credentials"] as? [String: Any])
        var bundle = try XCTUnwrap(credentials["fixture"] as? [String: Any])
        var metadata = try XCTUnwrap(bundle["metadata"] as? [String: Any])
        metadata["futureRequiredField"] = "synthetic-do-not-drop"
        bundle["metadata"] = metadata
        credentials["fixture"] = bundle
        object["credentials"] = credentials
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(JSONSerialization.data(withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes])))
    }

    func testAliasCollisionCannotChangeExistingCLIResolution() throws {
        var renamed = entry()
        renamed.metadata.aliases = ["old-id"]
        XCTAssertThrowsError(try snapshot(["new-id": renamed, "old-id": entry()]))
        let local = try snapshot(["new-id": renamed])
        let remote = try snapshot(["old-id": entry()])
        XCTAssertThrowsError(try CloudVaultMerge.merge(base: nil, local: local, remote: remote))
        var fields = entry()
        fields.metadata.fields["other-key"] = .init(secret: true, aliases: ["api-key"])
        fields.secrets["other-key"] = "synthetic-other"
        XCTAssertThrowsError(try snapshot(["fixture": fields]))
    }

    func testMetadataOnlyEditsAndSecretChangesRemainInSameConflictUnit() throws {
        let base = try snapshot(["a": entry()])
        let local = try snapshot(["a": entry(label: "New name")])
        let remote = try snapshot(["a": entry("synthetic-rotated")])
        let result = try CloudVaultMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(result.conflictingIDs, ["a"])
        XCTAssertThrowsError(try result.resolved())
        XCTAssertEqual(local.credentials["a"]?.metadata.label, "New name")
        XCTAssertEqual(remote.credentials["a"]?.secrets["api-key"], "synthetic-rotated")
    }

    func testSameLogicalChangeIsIdempotentAndIndependentOfArrivalOrder() throws {
        let base = try snapshot(["a": entry()])
        let changed = try snapshot(["a": entry("synthetic-new")])
        let once = try CloudVaultMerge.merge(base: base, local: changed, remote: changed).resolved()
        let twice = try CloudVaultMerge.merge(base: base, local: once, remote: changed).resolved()
        XCTAssertEqual(try once.encoded(), try twice.encoded())
        let reversed = try CloudVaultMerge.merge(base: base, local: changed, remote: once).resolved()
        XCTAssertEqual(try twice.encoded(), try reversed.encoded())
    }

    func testOversizedExportIsRefusedAndDebugDescriptionsAreRedacted() throws {
        let source = try snapshot(["fixture": entry()])
        XCTAssertFalse(String(describing: source).contains("synthetic"))
        XCTAssertFalse(String(reflecting: source).contains("synthetic"))
        XCTAssertFalse(String(reflecting: entry()).contains("synthetic"))
        XCTAssertThrowsError(try snapshot(["fixture": entry(String(repeating: "x",
            count: CloudVaultSnapshot.maximumBytes))]))
    }
}
