import XCTest
@testable import KeyKeeperCore

final class CloudMissingValueTests: XCTestCase {
    private func entry(_ value: String = "synthetic-value") -> CloudCredentialBundle {
        .init(metadata: Credential(label: "Synthetic", notes: "", links: [],
            fields: ["key": .init(secret: true)], security: .strict,
            created: "2026-11-04", updated: "2026-11-04"), secrets: ["key": value])
    }

    private func wireMissing(version: Int = 2) throws -> Data {
        let complete = try CloudVaultSnapshot(credentials: ["fixture": entry()])
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: complete.encoded()) as? [String: Any])
        var entries = try XCTUnwrap(wire["credentials"] as? [String: Any])
        var bundle = try XCTUnwrap(entries["fixture"] as? [String: Any])
        bundle["secrets"] = [String: String]()
        bundle["missingSecretFields"] = ["key"]
        entries["fixture"] = bundle
        wire["credentials"] = entries
        wire["version"] = version
        return try JSONSerialization.data(withJSONObject: wire, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    func testExplicitMissingRecordRoundTripsWithoutInventingAValue() throws {
        let data = try wireMissing()
        let restored = try CloudVaultSnapshot.decode(data)
        XCTAssertEqual(restored.credentials.count, 1)
        XCTAssertEqual(restored.credentials["fixture"]?.metadata.fields["key"]?.secret, true)
        XCTAssertEqual(restored.credentials["fixture"]?.secrets, [:])
        XCTAssertEqual(try restored.encoded(), data)
    }

    func testVersionOneCannotCarryMissingMarkers() throws {
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(wireMissing(version: 1)))
    }

    private func missing() -> CloudCredentialBundle {
        var result = entry()
        result.secrets = [:]
        result.missingSecretFields = ["key"]
        return result
    }

    private func snapshot(_ bundle: CloudCredentialBundle?) throws -> CloudVaultSnapshot {
        try .init(credentials: bundle.map { ["fixture": $0] } ?? [:])
    }

    func testCompatibleMissingIsRepairedFromCurrentPeerInEitherOrder() throws {
        let full = try snapshot(entry()), absent = try snapshot(missing())
        for base in [nil, full, absent] {
            for (left, right) in [(full, absent), (absent, full)] {
                let merged = try CloudVaultMerge.merge(base: base, local: left, remote: right).resolved()
                XCTAssertEqual(try merged.encoded(), try full.encoded())
            }
        }
    }

    func testIncompatibleMetadataCannotAutoEraseOrRebindPeerValue() throws {
        let full = try snapshot(entry())
        var changed = missing()
        changed.metadata.notes = "Different account contract"
        let absent = try snapshot(changed)
        for base in [nil, full] {
            for (left, right) in [(full, absent), (absent, full)] {
                let result = try CloudVaultMerge.merge(base: base, local: left, remote: right)
                XCTAssertEqual(result.conflictingIDs, ["fixture"])
                XCTAssertThrowsError(try result.resolved())
            }
        }
        for strict in [false, true] {
            XCTAssertThrowsError(try CloudVaultMerge.resolve(base: full, local: absent, remote: full,
                choices: ["fixture": .local], strict: strict))
            XCTAssertThrowsError(try CloudVaultMerge.resolve(base: full, local: full, remote: absent,
                choices: ["fixture": .remote], strict: strict))
        }
    }

    func testBothMissingDoNotResurrectHistoricalBaseValue() throws {
        let absent = try snapshot(missing())
        let merged = try CloudVaultMerge.merge(base: snapshot(entry("synthetic-obsolete")), local: absent, remote: absent).resolved()
        XCTAssertEqual(try merged.encoded(), try absent.encoded())
    }

    func testExactLegacyEncodingAndStoredRecoveryBytesRemainCompatible() throws {
        struct LegacyBundle: Encodable { let metadata: Credential; let secrets: [String: String] }
        struct LegacyWire: Encodable { let version: Int; let credentials: [String: LegacyBundle] }
        let bundle = entry()
        let bytes = try CloudVaultSnapshot.encode(LegacyWire(version: 1,
            credentials: ["fixture": .init(metadata: bundle.metadata, secrets: bundle.secrets)]))
        XCTAssertEqual(try snapshot(bundle).encoded(), bytes)
        XCTAssertEqual(try CloudVaultSnapshot.decode(bytes).encoded(), bytes)
        let revision = UUID(), token = Data("synthetic-token".utf8)
        let pending = CloudSyncPendingUpload(id: UUID(), snapshotData: bytes,
            expectedRevisionID: revision, expectedChangeToken: token)
        let state = CloudSyncStoredState(enabled: true,
            binding: .init(container: "synthetic", environment: "Production", accountID: "synthetic"),
            baseData: bytes, pending: pending,
            transition: .init(beforeData: bytes, desiredData: bytes, remoteData: bytes, upload: pending))
        try state.validate()
        let stateBytes = try CloudVaultSnapshot.encode(state)
        let restored = try JSONDecoder().decode(CloudSyncStoredState.self, from: stateBytes)
        try restored.validate()
        XCTAssertEqual(try CloudVaultSnapshot.encode(restored), stateBytes)
        XCTAssertEqual(try restored.pending?.snapshot().encoded(), bytes)
    }

    func testMalformedMissingMarkersAndNoncanonicalVersionsRefuse() throws {
        for fields in [["key", "key"], ["other"], []] {
            var invalid = missing(); invalid.missingSecretFields = fields
            XCTAssertThrowsError(try snapshot(invalid))
        }
        var overlap = entry(); overlap.missingSecretFields = ["key"]
        XCTAssertThrowsError(try snapshot(overlap))
        var plain = missing(); plain.metadata.fields["key"] = .init(value: "synthetic-plain", secret: false)
        XCTAssertThrowsError(try snapshot(plain))
        var unsorted = missing(); unsorted.metadata.fields["a"] = .init(secret: true)
        unsorted.missingSecretFields = ["key", "a"]
        XCTAssertThrowsError(try snapshot(unsorted))
        let complete = try snapshot(entry())
        var wire = try XCTUnwrap(JSONSerialization.jsonObject(with: complete.encoded()) as? [String: Any])
        wire["version"] = 2
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(JSONSerialization.data(withJSONObject: wire,
            options: [.sortedKeys, .withoutEscapingSlashes])))
        var missingWire = try XCTUnwrap(JSONSerialization.jsonObject(with: wireMissing()) as? [String: Any])
        missingWire["future"] = true
        XCTAssertThrowsError(try CloudVaultSnapshot.decode(JSONSerialization.data(withJSONObject: missingWire,
            options: [.sortedKeys, .withoutEscapingSlashes])))
        XCTAssertEqual(try snapshot(entry("")).missingFieldCount, 0, "An actual empty string is still a present value")
    }

    func testComplementaryMissingFieldsCombineButPresentConflictsRemain() throws {
        var a = entry(); a.metadata.fields["second"] = .init(secret: true); a.missingSecretFields = ["second"]
        var b = a; b.secrets = ["second": "synthetic-second"]; b.missingSecretFields = ["key"]
        let left = try snapshot(a), right = try snapshot(b)
        for (l, r) in [(left, right), (right, left)] {
            let merged = try CloudVaultMerge.merge(base: nil, local: l, remote: r).resolved()
            XCTAssertEqual(merged.credentials["fixture"]?.secrets, ["key": "synthetic-value", "second": "synthetic-second"])
            XCTAssertEqual(merged.missingFieldCount, 0)
        }
        b.secrets["key"] = "synthetic-different"; b.missingSecretFields = []
        let conflict = try CloudVaultMerge.merge(base: nil, local: left, remote: snapshot(b))
        XCTAssertEqual(conflict.conflictingIDs, ["fixture"])
    }

    func testStrictChoicesCompleteCompatibleMissingAndRejectUnsafeChoice() throws {
        let absent = try snapshot(missing()), full = try snapshot(entry())
        for choice in [CloudSyncChoice.local, .remote] {
            let resolved = try CloudVaultMerge.resolve(base: nil, local: absent, remote: full,
                choices: ["fixture": choice], strict: true)
            XCTAssertEqual(try resolved.encoded(), try full.encoded())
        }
        var changed = missing(); changed.metadata.fields["endpoint"] = .init(value: "https://example.invalid", secret: false)
        XCTAssertFalse(try CloudVaultMerge.canChoose(.local, local: changed, remote: entry()))
        XCTAssertTrue(try CloudVaultMerge.canChoose(.remote, local: changed, remote: entry()))
    }

    func testMissingRecordIsNotDeletionButExplicitFieldAndGroupDeletionStillWorks() throws {
        let absent = try snapshot(missing()), empty = try snapshot(nil)
        XCTAssertEqual(try CloudVaultMerge.merge(base: nil, local: empty, remote: absent).resolved().encoded(), try absent.encoded())
        for (l, r) in [(empty, absent), (absent, empty)] {
            XCTAssertTrue(try CloudVaultMerge.merge(base: absent, local: l, remote: r).resolved().credentials.isEmpty)
        }
        var removed = missing(); removed.metadata.fields.removeValue(forKey: "key"); removed.missingSecretFields = []
        let deletion = try snapshot(removed)
        for (l, r) in [(deletion, absent), (absent, deletion)] {
            let result = try CloudVaultMerge.merge(base: absent, local: l, remote: r).resolved()
            XCTAssertEqual(try result.encoded(), try deletion.encoded())
        }
    }
}
