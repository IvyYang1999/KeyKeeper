import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class LocalVaultJournalTests: XCTestCase {
    func testFreshAdmissionAndGenerationAreReadOnly() throws {
        let io = FakeKeychainIO()
        let marker = TestJournalMarker()
        let journal = LocalVaultJournal(io: io, marker: marker, namespace: "test")
        try journal.requireReady()
        XCTAssertEqual(try journal.generation(), LocalVaultJournal.initialGeneration)
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(marker.writes, 0)
    }

    func testMissingInitializedOrCorruptJournalBlocks() throws {
        let io = FakeKeychainIO()
        let marker = TestJournalMarker()
        marker.created = true
        let journal = LocalVaultJournal(io: io, marker: marker, namespace: "test")
        XCTAssertThrowsError(try journal.requireReady())
        io.blob = Data("not a journal".utf8)
        XCTAssertThrowsError(try journal.requireReady())
        XCTAssertEqual(io.writes, 0)
    }

    func testDeniedJournalAndMarkerAreNotTreatedAsFresh() throws {
        let io = FakeKeychainIO()
        let marker = TestJournalMarker()
        let journal = LocalVaultJournal(io: io, marker: marker, namespace: "test")
        io.failReads = true
        XCTAssertThrowsError(try journal.requireReady())
        XCTAssertThrowsError(try journal.generation())
        io.failReads = false
        marker.error = LocalVaultCommitError.unavailable
        XCTAssertThrowsError(try journal.requireReady())
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(io.ordinaryReads, 0)
    }

    func testStrictCodecRejectsForeignUnknownAndMalformedState() throws {
        let h = CommitHarness()
        _ = try h.committer.commit(h.plan)
        let valid = try XCTUnwrap(h.io.blob)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        for (key, value) in [("namespace", "foreign"), ("extra", "unknown"), ("lastDigest", "invalid")] {
            var changed = object
            changed[key] = value
            h.io.blob = try JSONSerialization.data(withJSONObject: changed, options: [.sortedKeys, .withoutEscapingSlashes])
            XCTAssertThrowsError(try h.journal.requireReady(), key)
        }
        object["generation"] = LocalVaultJournal.initialGeneration.uuidString
        h.io.blob = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try h.journal.requireReady())
        h.io.blob = Data(repeating: 32, count: LocalVaultJournal.maximumBytes + 1)
        XCTAssertThrowsError(try h.journal.requireReady())
    }

    func testMissingMarkerOnlyRecoversVirginBootstrapRecord() throws {
        let h = CommitHarness()
        h.marker.markError = true
        XCTAssertThrowsError(try h.committer.commit(h.plan))
        XCTAssertEqual(h.storage.effects, [])
        XCTAssertThrowsError(try h.journal.requireReady())
        h.marker.markError = false
        XCTAssertEqual(try h.restarted().recover(), [])
        try h.journal.requireReady()
        _ = try h.committer.recover()
        _ = try h.committer.commit(h.plan)
        h.marker.created = false
        XCTAssertThrowsError(try h.restarted().recover())
        XCTAssertFalse(h.marker.created)
    }

    func testInitializedJournalDeletionNeverRecreatesIt() throws {
        let h = CommitHarness()
        _ = try h.committer.commit(h.plan)
        h.io.blob = nil
        let writes = h.io.writes
        XCTAssertThrowsError(try h.restarted().recover())
        XCTAssertEqual(h.io.writes, writes)
        XCTAssertNil(h.io.blob)
    }

    func testNamespaceBindsBothServiceAndDirectory() {
        let a = URL(fileURLWithPath: "/tmp/keykeeper-synthetic-a")
        let b = URL(fileURLWithPath: "/tmp/keykeeper-synthetic-b")
        XCTAssertNotEqual(LocalVaultJournal.namespace(service: "one", directory: a),
                          LocalVaultJournal.namespace(service: "one", directory: b))
        XCTAssertNotEqual(LocalVaultJournal.namespace(service: "one", directory: a),
                          LocalVaultJournal.namespace(service: "two", directory: a))
    }

    func testDescriptionsDoNotPrintImageBytes() {
        let h = CommitHarness()
        for text in [String(describing: h.plan), String(reflecting: h.plan), String(reflecting: h.plan.before)] {
            XCTAssertFalse(text.contains("before-secret"))
            XCTAssertFalse(text.contains(Data("before-secret".utf8).base64EncodedString()))
        }
    }

    func testFileMarkerIsPrivateReadOnlyUntilInitializedAndRejectsSymlink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("marker")
        let marker = FileLocalVaultJournalMarker(url: url)
        XCTAssertFalse(try marker.wasCreated())
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try marker.markCreated()
        XCTAssertTrue(try marker.wasCreated())
        XCTAssertEqual(try Data(contentsOf: url), Data([1]))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let link = directory.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        let unsafe = FileLocalVaultJournalMarker(url: link)
        XCTAssertThrowsError(try unsafe.wasCreated())
        XCTAssertThrowsError(try unsafe.markCreated())
    }
}

final class TestJournalMarker: LocalVaultJournalMarker, @unchecked Sendable {
    var created = false
    var writes = 0
    var error: Error?
    var markError = false
    func wasCreated() throws -> Bool { if let error { throw error }; return created }
    func markCreated() throws {
        if let error { throw error }
        if markError { throw LocalVaultCommitError.unavailable }
        writes += 1; created = true
    }
}
