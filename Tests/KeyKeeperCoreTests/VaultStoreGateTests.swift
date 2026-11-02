import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class VaultStoreGateTests: XCTestCase {
    private enum Fault: Error { case stopped }
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-gate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPendingRecoveryBlocksAllStoresBeforeAnyIOButRawCLIReadRemainsCompatible() throws {
        let gate = VaultAccessGate()
        let integrity = FakeKeychainIO(), values = FakeKeychainIO(), approvalIO = FakeKeychainIO()
        let metadata = MetaStore(directory: directory, integrityIO: integrity, accessGate: gate)
        let blob = KeychainBlobStore(io: values, accessGate: gate)
        let approvals = ApprovalStore(io: approvalIO, accessGate: gate)
        try metadata.save(MetaFile())
        try blob.save(credentialId: "fixture", fieldName: "token", value: "synthetic")
        try approvals.setMode(.enforced)
        let before = (integrity.reads, values.ordinaryReads, approvalIO.ordinaryReads,
                      integrity.writes, values.writes, approvalIO.writes)
        let raw = try Data(contentsOf: metadata.fileURL)
        XCTAssertThrowsError(try gate.withCommit { throw Fault.stopped })

        XCTAssertThrowsError(try metadata.loadVerified())
        XCTAssertThrowsError(try metadata.loadForUse())
        XCTAssertThrowsError(try metadata.prepareForMutation())
        XCTAssertThrowsError(try metadata.save(MetaFile()))
        XCTAssertThrowsError(try metadata.trustCurrentMetadata())
        XCTAssertThrowsError(try blob.retrieve(credentialId: "fixture", fieldName: "token"))
        XCTAssertThrowsError(try blob.save(credentialId: "fixture", fieldName: "token", value: "replacement"))
        XCTAssertThrowsError(try blob.delete(credentialId: "fixture", fieldName: "token"))
        XCTAssertThrowsError(try blob.inspectValueInventory())
        XCTAssertThrowsError(try approvals.all())
        XCTAssertThrowsError(try approvals.setMode(.permissive))
        XCTAssertThrowsError(try approvals.pruneExpired())
        XCTAssertNoThrow(try metadata.load(), "CLI raw metadata remains independent of native stores")
        XCTAssertEqual(integrity.reads, before.0)
        XCTAssertEqual(values.ordinaryReads, before.1)
        XCTAssertEqual(approvalIO.ordinaryReads, before.2)
        XCTAssertEqual(integrity.writes, before.3)
        XCTAssertEqual(values.writes, before.4)
        XCTAssertEqual(approvalIO.writes, before.5)
        XCTAssertEqual(try Data(contentsOf: metadata.fileURL), raw)

        try gate.withRecovery {}
        XCTAssertEqual(try blob.retrieve(credentialId: "fixture", fieldName: "token"), "synthetic")
        XCTAssertEqual(try metadata.loadVerified().verdict, .intact)
        XCTAssertEqual(try approvals.mode(), .enforced)
    }

    func testPreparedImageNeverBootstrapsAndMatchesNormalSaveEncoding() throws {
        let io = FakeKeychainIO()
        let store = MetaStore(directory: directory, integrityIO: io)
        XCTAssertThrowsError(try store.preparedSignedData(MetaFile()))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        try store.save(MetaFile())
        var candidate = try store.loadForUse()
        candidate.storeInitialized = true
        let original = try Data(contentsOf: store.fileURL)
        let image = try store.preparedSignedData(candidate)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        try store.save(candidate)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), image)
    }

    func testCapturedApprovalCanBeSelectedAmongOverlappingGrantsAndRevocationIsFinal() throws {
        let gate = VaultAccessGate()
        let store = ApprovalStore(io: FakeKeychainIO(), accessGate: gate)
        let subject = ApprovalSubject(fingerprint: "app:team=T:bundle=fixture:signing=x", displayName: "Fixture")
        let target = ApprovalTarget.credential(id: "fixture", fields: nil)
        let first = Approval(subject: subject, target: target, duration: .always)
        let captured = Approval(subject: subject, target: target, duration: .timed(Date().addingTimeInterval(60)))
        try store.add(first)
        try store.add(captured)
        XCTAssertEqual(try store.valid(credentialId: "fixture", field: "token", fingerprint: subject.fingerprint,
                                       terminalSession: nil)?.id, first.id)
        XCTAssertEqual(try store.valid(credentialId: "fixture", field: "token", fingerprint: subject.fingerprint,
                                       terminalSession: nil, approvalID: captured.id)?.id, captured.id)
        try store.revoke(id: captured.id)
        XCTAssertNil(try store.valid(credentialId: "fixture", field: "token", fingerprint: subject.fingerprint,
                                    terminalSession: nil, approvalID: captured.id))
        XCTAssertEqual(try store.valid(credentialId: "fixture", field: "token", fingerprint: subject.fingerprint,
                                       terminalSession: nil)?.id, first.id)
    }

    func testPrivateRawTransactionAdapterDoesNotOpenPublicStores() throws {
        let gate = VaultAccessGate()
        let io = FakeKeychainIO()
        let publicStore = ApprovalStore(io: io, accessGate: gate)
        let adapterStore = ApprovalStore(io: io)
        try gate.withAccess {
            try gate.withCommit {
                try adapterStore.setMode(.enforced)
                XCTAssertThrowsError(try publicStore.mode())
            }
        }
        XCTAssertEqual(try publicStore.mode(), .enforced)
    }
}
