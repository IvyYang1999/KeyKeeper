import Darwin
import Foundation
import XCTest
@testable import KeyKeeperApp
@testable import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class IPCVaultGateTests: XCTestCase {
    private var directory: URL!
    private var metadata: MetaStore!
    private var approvals: ApprovalStore!
    private var gate: VaultAccessGate!
    private let caller = CallerIdentity(peerPID: 123, subject: .init(
        kind: .executable, fingerprint: "test:vault-epoch", displayName: "Synthetic caller", detail: "fixture"))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ipc-vault-gate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metadata = MetaStore(directory: directory)
        try metadata.save(MetaFile(credentials: ["fixture": .init(label: "Synthetic credential", notes: "", links: [],
            fields: ["token": .init(secret: true)], security: .strict, created: "2026-11-02", updated: "2026-11-02")]))
        approvals = .inMemory()
        gate = VaultAccessGate()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// A metadata fingerprint alone cannot detect rotation of only the protected value.
    func testStrictPendingApprovalRejectsSecretOnlyCommitEpoch() throws {
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals, accessGate: gate)
        let pair = try sockets()
        defer { close(pair.1); server.stop() }
        server.handleAuthRequest(.init(credentialId: "fixture", credentialLabel: "ignored", fieldNames: [],
            sessionId: nil, sessionLabel: nil, pid: 0), clientFd: pair.0, callerIdentity: caller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let pending = try XCTUnwrap(server.pendingRequest)
        let before = try Data(contentsOf: metadata.fileURL)
        try gate.withCommit { session.value = "synthetic-rotated" }
        XCTAssertEqual(try Data(contentsOf: metadata.fileURL), before, "Only the value changed")
        XCTAssertThrowsError(try server.approveAuthRequest(pending, choice: .always)) {
            XCTAssertEqual($0 as? VaultAccessError, .staleEpoch)
        }
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertEqual(session.reads, 0)
        if server.pendingRequest != nil { server.denyPending() }
        _ = try response(pair.1)
    }

    func testFreshStrictApprovalStillIssuesGrant() throws {
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals, accessGate: gate)
        let pair = try sockets()
        defer { close(pair.1) }
        server.handleAuthRequest(.init(credentialId: "fixture", credentialLabel: "ignored", fieldNames: [],
            sessionId: nil, sessionLabel: nil, pid: 0), clientFd: pair.0, callerIdentity: caller)
        drainMain()
        try server.approveAuthRequest(XCTUnwrap(server.pendingRequest), choice: .always)
        guard case .auth(let result) = try response(pair.1) else { return XCTFail("Expected auth response") }
        XCTAssertTrue(result.granted)
        XCTAssertEqual(try approvals.all().count, 1)
        XCTAssertEqual(session.reads, 0)
    }

    func testPendingServiceApprovalRejectsSecretOnlyCommitEpoch() throws {
        try setStandard()
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals, accessGate: gate)
        let pair = try sockets()
        defer { close(pair.1) }
        let pending = try serviceRequest(server, fd: pair.0)
        try gate.withCommit { session.value = "synthetic-rotated" }
        XCTAssertThrowsError(try server.approveServiceRequest(pending, choice: .always)) {
            XCTAssertEqual($0 as? VaultAccessError, .staleEpoch)
        }
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertEqual(session.reads, 0)
        server.denyServiceRequest(pending)
        _ = try response(pair.1)
    }

    func testStandingApprovalRequiresOriginalEpochAndFreshEpochWorks() throws {
        let server = IPCServer(session: EpochSession(), metaStore: metadata, approvals: approvals, accessGate: gate)
        let event = ServiceAuditEvent(timestamp: Date(), credentialId: "fixture", fieldName: "token",
            subjectFingerprint: caller.subjectFingerprint, subjectDisplayName: caller.displayName,
            mode: .enforced, decision: "prompt_required")
        let group = try XCTUnwrap(AccessLogBuilder.groups(AccessLogBuilder.entries(approvals: [], auditEvents: [event])).first)
        let request = try XCTUnwrap(StandingApprovalRequest(group: group, credentialLabel: "Synthetic credential", fieldNames: ["token"]))
        let epoch = try server.captureVaultEpoch()
        try gate.withCommit {}
        for stale in [epoch, nil] {
            XCTAssertThrowsError(try server.approveStandingRequest(request, choice: .always, expectedEpoch: stale)) {
                XCTAssertEqual($0 as? VaultAccessError, .staleEpoch)
            }
        }
        XCTAssertTrue(try approvals.all().isEmpty)
        try server.approveStandingRequest(request, choice: .always, expectedEpoch: server.captureVaultEpoch())
        XCTAssertEqual(try approvals.all().count, 1)
    }

    func testQueuedFulfillmentRejectsSecretOnlyCommitAfterApproval() throws {
        try queuedFulfillment(change: { session, _, gate in
            try gate.withCommit { session.value = "synthetic-rotated" }
        }, succeeds: false)
    }

    func testQueuedFulfillmentRejectsRevokedGrant() throws {
        try queuedFulfillment(change: { _, approvals, _ in
            let id = try XCTUnwrap(approvals.all().first?.id)
            XCTAssertTrue(try approvals.revoke(id: id))
        }, succeeds: false)
    }

    func testQueuedFulfillmentRejectsAlreadyConsumedGrant() throws {
        try queuedFulfillment(change: { _, approvals, _ in
            let id = try XCTUnwrap(approvals.all().first?.id)
            try approvals.noteUse(id: id, field: "token")
        }, succeeds: false)
    }

    func testQueuedFulfillmentWithUnchangedEpochAndGrantStillReadsOnce() throws {
        try queuedFulfillment(change: { _, _, _ in }, succeeds: true)
    }

    func testFailedAdmissionReturnsNoValueOrPrompt() throws {
        let closedGate = VaultAccessGate { throw VaultAccessError.recoveryRequired }
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals, accessGate: closedGate)
        let pair = try sockets()
        defer { close(pair.1) }
        server.handleValueRequest(.init(credentialId: "fixture", fieldName: "token", sessionId: nil),
                                  clientFd: pair.0, callerIdentity: caller)
        guard case .value(let result) = try response(pair.1) else { return XCTFail("Expected value response") }
        XCTAssertFalse(result.success)
        XCTAssertNil(result.value)
        XCTAssertEqual(result.storageErrorCode, .readFailed)
        XCTAssertEqual(session.reads, 0)
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertNil(server.pendingRequest)
        XCTAssertNil(server.pendingServiceRequest)
    }

    func testImmediateReadExcludesCommitUntilGrantUseIsRecorded() throws {
        let approval = Approval(subject: .init(fingerprint: caller.subjectFingerprint, displayName: caller.displayName),
            target: .credential(id: "fixture", fields: ["token"]), duration: .once, onceFieldsRemaining: ["token"])
        try approvals.add(approval)
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals, accessGate: gate)
        let attempted = DispatchSemaphore(value: 0)
        let committed = DispatchSemaphore(value: 0)
        let probe = CommitProbe()
        let gate = try XCTUnwrap(gate)
        let approvals = try XCTUnwrap(approvals)
        session.onRead = {
            DispatchQueue.global().async {
                attempted.signal()
                do {
                    try gate.withCommit {
                        probe.record(consumed: try approvals.all().first?.consumed == true)
                    }
                } catch { probe.record(error: error) }
                committed.signal()
            }
            XCTAssertEqual(attempted.wait(timeout: .now() + 1), .success)
            XCTAssertEqual(committed.wait(timeout: .now() + 0.1), .timedOut,
                           "Commit must not split policy, secret read, and once-grant use")
        }
        let pair = try sockets()
        defer { close(pair.1) }
        server.handleValueRequest(.init(credentialId: "fixture", fieldName: "token", sessionId: nil),
                                  clientFd: pair.0, callerIdentity: caller)
        XCTAssertEqual(committed.wait(timeout: .now() + 2), .success)
        guard case .value(let result) = try response(pair.1) else { return XCTFail("Expected value response") }
        XCTAssertTrue(result.success)
        XCTAssertEqual(session.reads, 1)
        XCTAssertTrue(probe.sawConsumed)
        XCTAssertNil(probe.error)
    }

    private func queuedFulfillment(change: (EpochSession, ApprovalStore, VaultAccessGate) throws -> Void,
                                   succeeds: Bool) throws {
        try setStandard()
        let queue = DispatchQueue(label: "test.ipc.queued-epoch")
        let session = EpochSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals,
                               accessGate: gate, workerQueue: queue)
        let pair = try sockets()
        defer { close(pair.1) }
        let pending = try serviceRequest(server, fd: pair.0)
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        try server.approveServiceRequest(pending, choice: .once)
        XCTAssertEqual(try approvals.all().count, 1, "Start with an issued grant")
        XCTAssertEqual(session.reads, 0, "The worker has not retrieved anything yet")
        try change(session, approvals, gate)
        resumed = true
        queue.resume()
        guard case .value(let result) = try response(pair.1) else { return XCTFail("Expected value response") }
        XCTAssertEqual(result.success, succeeds)
        XCTAssertEqual(result.value, succeeds ? "synthetic-original" : nil)
        XCTAssertEqual(session.reads, succeeds ? 1 : 0)
        if succeeds { XCTAssertTrue(try XCTUnwrap(approvals.all().first).consumed) }
    }

    private func setStandard() throws {
        var file = try metadata.loadForUse()
        file.credentials["fixture"]?.security = .standard
        try metadata.save(file)
        try approvals.setMode(.enforced)
    }

    private func serviceRequest(_ server: IPCServer, fd: Int32) throws -> IPCServer.PendingServiceRequest {
        server.handleValueRequest(.init(credentialId: "fixture", fieldName: "token", sessionId: nil),
                                  clientFd: fd, callerIdentity: caller)
        drainMain()
        return try XCTUnwrap(server.pendingServiceRequest)
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

private final class EpochSession: SessionControlling, @unchecked Sendable {
    var isVaultInitialized = true
    var reads = 0
    var value = "synthetic-original"
    var onRead: (() -> Void)?
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func unlock(passphrase: String) throws {}
    func lock() {}
    func retrieve(credentialId: String, fieldName: String) throws -> String { reads += 1; onRead?(); return value }
}

private final class CommitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false
    private var failure: Error?
    var sawConsumed: Bool { lock.lock(); defer { lock.unlock() }; return consumed }
    var error: Error? { lock.lock(); defer { lock.unlock() }; return failure }
    func record(consumed: Bool) { lock.lock(); defer { lock.unlock() }; self.consumed = consumed }
    func record(error: Error) { lock.lock(); defer { lock.unlock() }; failure = error }
}
