import XCTest
import Darwin
@testable import KeyKeeperApp
@testable import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class IPCVaultRevisionTests: XCTestCase {
    private var directory: URL!
    private var meta: MetaStore!
    private var values: KeychainBlobStore!
    private var valueIO: FakeKeychainIO!
    private var approvals: ApprovalStore!
    private var gate: VaultAccessGate!
    private var server: IPCServer!
    private let caller = CallerIdentity(peerPID: 1, executablePath: "/synthetic", bundleIdentifier: nil,
        teamIdentifier: nil, signingIdentifier: nil, parentChain: [],
        subject: CallerSubject(kind: .executable, fingerprint: "synthetic-caller", displayName: "Synthetic", detail: ""))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gate = VaultAccessGate()
        meta = MetaStore(directory: directory, accessGate: gate)
        try meta.save(MetaFile(credentials: ["fixture": .init(label: "Synthetic", notes: "", links: [],
            fields: ["key": .init(secret: true), "base": .init(value: "https://synthetic.invalid", secret: false)],
            security: .standard, created: "2026-11-02", updated: "2026-11-02", aliases: ["alias"])]))
        valueIO = FakeKeychainIO()
        try KeychainBlobStore(io: valueIO, accessGate: gate).save(credentialId: "fixture", fieldName: "key", value: "synthetic-original")
        values = KeychainBlobStore(io: valueIO, loadMetadata: { try self.meta.loadForUse() }, accessGate: gate)
        approvals = ApprovalStore(io: FakeKeychainIO(), accessGate: gate)
        try approvals.setMode(.permissive)
        server = makeServer()
    }

    override func tearDownWithError() throws {
        server = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeServer(required: @escaping @Sendable () throws -> Bool = { false },
                            worker: DispatchQueue? = nil) -> IPCServer {
        IPCServer(session: KeychainCredentialService(store: values), metaStore: meta, approvals: approvals,
                  accessGate: gate, workerQueue: worker, requiresBoundRequests: required)
    }

    func testAuthoritativeSnapshotContainsMetadataAndSameGateInventory() throws {
        let result = try server.handleVaultSnapshot(.init(inspectValues: true)).validated()
        XCTAssertEqual(result.metadata?.credentials["fixture"]?.fields["base"]?.value, "https://synthetic.invalid")
        XCTAssertEqual(result.valueInventory?["fixture"], ["key"])
        XCTAssertNil(result.metadata?.credentials["fixture"]?.fields["key"]?.value)
        XCTAssertNoThrow(try gate.validateRevision(result.revision, metadata: meta.loadForUse(), required: true))
    }
    func testUnchangedRevisionReadsThroughAlias() throws {
        let revision = try snapshot()
        let response = try read(revision: revision, id: "alias")
        XCTAssertTrue(response.success)
        XCTAssertEqual(response.value, "synthetic-original")
    }

    func testSecretOnlyMutationRejectsOldRevisionBeforeReadingOrPrompting() throws {
        let revision = try snapshot()
        let metadataBefore = try Data(contentsOf: meta.fileURL)
        try values.save(credentialId: "fixture", fieldName: "key", value: "synthetic-rotated")
        XCTAssertEqual(try Data(contentsOf: meta.fileURL), metadataBefore)
        let reads = valueIO.ordinaryReads
        let result = try read(revision: revision)
        XCTAssertEqual(result.revisionError, .stale)
        XCTAssertNil(result.value)
        XCTAssertEqual(valueIO.ordinaryReads, reads)
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertNil(server.pendingServiceRequest)
    }

    func testMetadataChangeAndCommitInvalidateOriginalRevision() throws {
        let revision = try snapshot()
        try changeMetadata()
        XCTAssertEqual(try read(revision: revision).revisionError, .stale)
        let second = try snapshot()
        try gate.withCommit {}
        XCTAssertEqual(try read(revision: second).revisionError, .stale)
    }

    func testNewProcessInstanceRejectsOldToken() throws {
        let revision = try snapshot()
        let newGate = VaultAccessGate()
        server = IPCServer(session: KeychainCredentialService(store: values), metaStore: meta,
                           approvals: approvals, accessGate: newGate)
        XCTAssertEqual(try read(revision: revision).revisionError, .stale)
    }

    func testLegacyRequestsAllowedBeforeJournalAndDeniedAfterInitialization() throws {
        XCTAssertTrue(try read(revision: nil).success)
        XCTAssertEqual(server.handleLegacyMetadataIntegrity().verdict, .unsigned)
        server = makeServer(required: { true })
        let reads = valueIO.ordinaryReads
        XCTAssertEqual(try read(revision: nil).revisionError, .required)
        XCTAssertEqual(valueIO.ordinaryReads, reads)
        XCTAssertEqual(server.handleLegacyMetadataIntegrity().verdict, .tampered)
        let pair = try sockets()
        defer { close(pair.1) }
        auth(revision: nil, fd: pair.0)
        guard case .auth(let response) = try response(pair.1) else { return XCTFail("Expected auth") }
        XCTAssertFalse(response.granted)
        XCTAssertEqual(response.revisionError, .required)
        XCTAssertNil(server.pendingRequest)
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertTrue(try read(revision: snapshot()).success, "Bound clients remain usable")
    }

    func testRequiredPolicyReadFailureCannotDowngrade() throws {
        server = makeServer(required: { throw VaultRevisionError.unavailable })
        let result = try read(revision: nil)
        XCTAssertEqual(result.revisionError, .unavailable)
        XCTAssertNil(result.value)
    }

    func testPendingBoundAuthBecomesTerminalStaleWithoutGrant() throws {
        let pair = try sockets()
        defer { close(pair.1) }
        auth(revision: try snapshot(), fd: pair.0)
        drainMain()
        let pending = try XCTUnwrap(server.pendingRequest)
        try changeMetadata()
        XCTAssertThrowsError(try server.approveAuthRequest(pending, choice: .always)) {
            XCTAssertEqual($0 as? VaultRevisionError, .stale)
        }
        guard case .auth(let result) = try response(pair.1) else { return XCTFail("Expected auth") }
        XCTAssertEqual(result.revisionError, .stale)
        XCTAssertFalse(result.granted)
        XCTAssertNil(server.pendingRequest)
        XCTAssertTrue(try approvals.all().isEmpty)
    }

    func testPendingBoundServiceBecomesTerminalStaleWithoutGrant() throws {
        try approvals.setMode(.enforced)
        let pair = try sockets()
        defer { close(pair.1) }
        service(revision: try snapshot(), fd: pair.0)
        drainMain()
        let pending = try XCTUnwrap(server.pendingServiceRequest)
        try values.save(credentialId: "fixture", fieldName: "key", value: "synthetic-rotated")
        XCTAssertThrowsError(try server.approveServiceRequest(pending, choice: .always))
        guard case .value(let result) = try response(pair.1) else { return XCTFail("Expected value") }
        XCTAssertEqual(result.revisionError, .stale)
        XCTAssertNil(result.value)
        XCTAssertNil(server.pendingServiceRequest)
        XCTAssertTrue(try approvals.all().isEmpty)
    }

    func testQueuedBoundFulfillmentRejectsMetadataChangeWithoutSpendingGrant() throws {
        try approvals.setMode(.enforced)
        let queue = DispatchQueue(label: "revision-fixture")
        server = makeServer(worker: queue)
        let pair = try sockets()
        defer { close(pair.1) }
        service(revision: try snapshot(), fd: pair.0)
        drainMain()
        let pending = try XCTUnwrap(server.pendingServiceRequest)
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        try server.approveServiceRequest(pending, choice: .once)
        let issued = try XCTUnwrap(approvals.all().first)
        XCTAssertFalse(issued.consumed)
        try changeMetadata()
        let reads = valueIO.ordinaryReads
        resumed = true
        queue.resume()
        guard case .value(let result) = try response(pair.1) else { return XCTFail("Expected value") }
        XCTAssertEqual(result.revisionError, .stale)
        XCTAssertNil(result.value)
        XCTAssertEqual(valueIO.ordinaryReads, reads)
        XCTAssertFalse(try XCTUnwrap(approvals.all().first).consumed)
    }

    func testBlockedGateReturnsNoSnapshotOrInventory() throws {
        let blocked = VaultAccessGate { throw VaultAccessError.recoveryRequired }
        server = IPCServer(session: KeychainCredentialService(store: values), metaStore: meta,
                           approvals: approvals, accessGate: blocked)
        let result = server.handleVaultSnapshot(.init(inspectValues: true))
        XCTAssertFalse(result.success)
        XCTAssertNil(result.metadata)
        XCTAssertNil(result.revision)
        XCTAssertNil(result.valueInventory)
    }

    private func snapshot() throws -> VaultRevision {
        try XCTUnwrap(server.handleVaultSnapshot(.init()).validated().revision)
    }
    private func changeMetadata() throws {
        var metadata = try meta.loadForUse()
        metadata.credentials["fixture"]?.notes = "changed synthetic note"
        try meta.save(metadata)
    }
    private func service(revision: VaultRevision?, fd: Int32, id: String = "fixture") {
        server.handleValueRequest(.init(credentialId: id, fieldName: "key", sessionId: nil, revision: revision),
                                  clientFd: fd, callerIdentity: caller)
    }
    private func auth(revision: VaultRevision?, fd: Int32) {
        server.handleAuthRequest(.init(credentialId: "fixture", credentialLabel: "ignored", fieldNames: [],
            sessionId: nil, sessionLabel: nil, pid: 0, revision: revision), clientFd: fd, callerIdentity: caller)
    }
    private func read(revision: VaultRevision?, id: String = "fixture") throws -> ValueResponse {
        let pair = try sockets()
        defer { close(pair.1) }
        service(revision: revision, fd: pair.0, id: id)
        guard case .value(let result) = try response(pair.1) else { throw IPCError.readFailed }
        return result
    }
    private func drainMain() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    private func sockets() throws -> (Int32, Int32) {
        var pair = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw IPCError.readFailed }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (pair[0], pair[1])
    }
    private func response(_ fd: Int32) throws -> IPCResponse {
        guard let result = IPCMessage.readMessage(fd: fd, as: IPCResponse.self) else { throw IPCError.readFailed }
        return result
    }

}
