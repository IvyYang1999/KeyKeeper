import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport

private final class ProposalMarker: BrowserImportProposalMarker, @unchecked Sendable {
    var created = false
    func wasCreated() throws -> Bool { created }
    func markCreated() throws { created = true }
}

final class BrowserImportProposalStoreTests: XCTestCase {
    private let id = String(repeating: "a", count: 64)

    private func staged(deadline: Date) -> BrowserImportProposalRecord {
        BrowserImportProposalRecord(
            snapshot: .init(id: id, credentialId: "fixture", fieldName: "api-key",
                            state: .pasteReceived, deadline: deadline,
                            nextAction: "Approve or cancel in KeyKeeper."),
            request: .init(credentialId: "fixture", fieldName: "api-key", create: true),
            callerName: "Synthetic test",
            candidate: "synthetic-browser-candidate",
            metadataFingerprint: Data(repeating: 1, count: 32),
            targetValueFingerprint: nil,
            createdAt: deadline.addingTimeInterval(-60),
            updatedAt: deadline.addingTimeInterval(-60)
        )
    }

    func testStagedCandidateSurvivesStoreRecreationAndTerminalTransitionScrubsIt() throws {
        let keychain = FakeKeychain(), marker = ProposalMarker()
        let store = BrowserImportProposalStore(io: keychain.io("proposal"), marker: marker)
        let deadline = Date().addingTimeInterval(600)
        try store.stage(staged(deadline: deadline))

        let reopened = BrowserImportProposalStore(io: keychain.io("proposal"), marker: marker)
        XCTAssertEqual(try reopened.record(id: id)?.candidate, "synthetic-browser-candidate")
        XCTAssertTrue(marker.created)

        var committed = staged(deadline: deadline).snapshot
        committed.state = .committed
        committed.deadline = nil
        committed.nextAction = nil
        try reopened.finish(id: id, snapshot: committed, now: deadline)

        let bytes = try XCTUnwrap(keychain["proposal"])
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic-browser-candidate"))
        let terminal = try BrowserImportProposalStore(io: keychain.io("proposal"), marker: marker).record(id: id)
        XCTAssertEqual(terminal?.snapshot.state, .committed)
        XCTAssertNil(terminal?.candidate)
        XCTAssertNil(terminal?.request)
        XCTAssertNil(terminal?.metadataFingerprint)
    }

    func testMissingPreviouslyCreatedStoreFailsClosed() throws {
        let marker = ProposalMarker(); marker.created = true
        let store = BrowserImportProposalStore(io: FakeKeychainIO(), marker: marker)
        XCTAssertThrowsError(try store.records()) { error in
            XCTAssertEqual(error as? BrowserImportProposalStoreError, .unavailable)
        }
    }

    func testSecondOpenProposalIsRejectedWithoutReplacingFirstCandidate() throws {
        let keychain = FakeKeychain(), marker = ProposalMarker()
        let store = BrowserImportProposalStore(io: keychain.io("proposal"), marker: marker)
        let deadline = Date().addingTimeInterval(600)
        try store.stage(staged(deadline: deadline))
        var second = staged(deadline: deadline)
        second.snapshot.id = String(repeating: "b", count: 64)
        second.snapshot.credentialId = "other"
        second.request?.credentialId = "other"
        second.candidate = "different-candidate"

        XCTAssertThrowsError(try store.stage(second)) { error in
            XCTAssertEqual(error as? BrowserImportProposalStoreError, .busy)
        }
        XCTAssertEqual(try store.record(id: id)?.candidate, "synthetic-browser-candidate")
    }

    func testCorruptOrOversizedRecordNeverLoadsAsEmpty() throws {
        let marker = ProposalMarker(), io = FakeKeychainIO(blob: Data("not-json".utf8))
        marker.created = true
        XCTAssertThrowsError(try BrowserImportProposalStore(io: io, marker: marker).records()) { error in
            XCTAssertEqual(error as? BrowserImportProposalStoreError, .unavailable)
        }

        let store = BrowserImportProposalStore(io: FakeKeychainIO(), marker: ProposalMarker())
        var record = staged(deadline: Date().addingTimeInterval(600))
        record.candidate = String(repeating: "x", count: 65_537)
        XCTAssertThrowsError(try store.stage(record))
    }
}
