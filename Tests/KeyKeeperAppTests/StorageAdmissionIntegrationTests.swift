import Darwin
import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class StorageAdmissionIntegrationTests: XCTestCase {
    private var directory: URL!
    private var integrity: FakeKeychainIO!
    private var metadata: MetaStore!
    private var approvals: ApprovalStore!
    private let caller = CallerIdentity(peerPID: 123, subject: .init(
        kind: .executable, fingerprint: "test:admission", displayName: "Synthetic caller", detail: "fixture"))

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        integrity = FakeKeychainIO()
        metadata = MetaStore(directory: directory, integrityIO: integrity)
        try metadata.save(MetaFile(credentials: ["fixture": Credential(
            label: "Synthetic credential", notes: "", links: [],
            fields: ["token": CredentialField(secret: true)], security: .standard,
            created: "2026-11-02", updated: "2026-11-02")]))
        approvals = .inMemory()
        try approvals.setMode(.permissive)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// 【曾经的 bug】服务端把校验异常吞掉，仍读值并记授权使用。
    func testDeniedIntegrityRejectsValueBeforeSecretOrGrantEffects() throws {
        let session = AdmissionSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals)
        let before = try Data(contentsOf: metadata.fileURL)
        integrity.failReads = true
        let pair = try sockets()
        defer { close(pair.1) }
        server.handleValueRequest(.init(credentialId: "fixture", fieldName: "token", sessionId: nil),
                                  clientFd: pair.0, callerIdentity: caller)
        guard case .value(let response) = try response(pair.1) else { return XCTFail("wrong response") }
        XCTAssertFalse(response.success)
        XCTAssertEqual(session.reads, 0)
        XCTAssertTrue(try approvals.auditEvents().isEmpty)
        XCTAssertNil(server.pendingRequest)
        XCTAssertNil(server.pendingServiceRequest)
        XCTAssertEqual(try Data(contentsOf: metadata.fileURL), before)
    }

    /// 首启要先过 admission，不能在校验失败后迁移旧授权或清理已过期授权。
    func testDeniedIntegritySkipsAllLaunchMaintenance() throws {
        let legacy = directory.appendingPathComponent("grants.json")
        let legacyBytes = Data("{\"grants\":[]}".utf8)
        try legacyBytes.write(to: legacy)
        let expired = Approval(subject: .init(fingerprint: "test:expired", displayName: "Fixture"),
            target: .credential(id: "fixture", fields: nil), duration: .timed(Date(timeIntervalSince1970: 1)))
        try approvals.add(expired)
        let originalApprovals = try approvals.all()
        let before = try Data(contentsOf: metadata.fileURL)
        integrity.failReads = true
        var inventoryReads = 0
        LaunchMaintenance.run(.init(meta: metadata, inventory: {
            inventoryReads += 1
            return ["fixture": ["token"]]
        }, approvals: approvals, directory: directory, sessionStore: nil))
        XCTAssertEqual(inventoryReads, 0)
        XCTAssertEqual(try Data(contentsOf: metadata.fileURL), before)
        XCTAssertEqual(try Data(contentsOf: legacy), legacyBytes)
        XCTAssertEqual(try approvals.all().map(\.id), originalApprovals.map(\.id))
    }

    func testDeniedIntegrityDoesNotRestoreImportJournal() throws {
        let journalIO = FakeKeychainIO()
        let journal = BrowserImportProposalStore(io: journalIO,
            marker: FileBrowserImportProposalMarker(directory: directory))
        let server = IPCServer(session: AdmissionSession(), metaStore: metadata, approvals: approvals,
                               browserImportProposalStore: journal)
        integrity.failReads = true
        server.restoreBrowserImportProposal()
        XCTAssertEqual(journalIO.ordinaryReads, 0)
        XCTAssertEqual(journalIO.writes, 0)
        integrity.failReads = false
        server.restoreBrowserImportProposal()
        XCTAssertGreaterThan(journalIO.ordinaryReads, 0, "The admitted control must actually reach journal restore")
    }

    func testDelayedServiceApprovalRechecksIntegrityAndCurrentCredential() throws {
        try approvals.setMode(.enforced)
        let session = AdmissionSession()
        let server = IPCServer(session: session, metaStore: metadata, approvals: approvals)
        let pair = try sockets()
        defer { close(pair.1); server.stop() }
        server.handleValueRequest(.init(credentialId: "fixture", fieldName: "token", sessionId: nil),
                                  clientFd: pair.0, callerIdentity: caller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let pending = try XCTUnwrap(server.pendingServiceRequest)
        integrity.failReads = true
        XCTAssertThrowsError(try server.approveServiceRequest(pending, choice: .always))
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertEqual(session.reads, 0)
        integrity.failReads = false
        var changed = try metadata.loadForUse()
        changed.credentials["fixture"]?.security = .strict
        try metadata.save(changed)
        XCTAssertThrowsError(try server.approveServiceRequest(pending, choice: .always))
        XCTAssertTrue(try approvals.all().isEmpty)
        XCTAssertEqual(session.reads, 0)
        server.denyServiceRequest(pending)
        _ = try response(pair.1)
    }

    func testDelayedStrictApprovalAndRecoveryUseTheSamePendingRequest() throws {
        let server = IPCServer(session: AdmissionSession(), metaStore: metadata, approvals: approvals)
        let pair = try sockets()
        defer { close(pair.1); server.stop() }
        server.handleAuthRequest(.init(credentialId: "fixture", credentialLabel: "ignored",
            fieldNames: [], sessionId: nil, sessionLabel: nil, pid: 0), clientFd: pair.0, callerIdentity: caller)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let pending = try XCTUnwrap(server.pendingRequest)
        integrity.failReads = true
        XCTAssertThrowsError(try server.approveAuthRequest(pending, choice: .always))
        XCTAssertTrue(try approvals.all().isEmpty)
        integrity.failReads = false
        try server.approveAuthRequest(pending, choice: .always)
        guard case .auth(let reply) = try response(pair.1) else { return XCTFail("wrong response") }
        XCTAssertTrue(reply.granted)
        XCTAssertEqual(try approvals.all().count, 1)
        XCTAssertNil(server.pendingRequest)
    }

    func testDeniedIntegrityAuthRequestNeverEntersApprovalQueue() throws {
        let server = IPCServer(session: AdmissionSession(), metaStore: metadata, approvals: approvals)
        let pair = try sockets()
        defer { close(pair.1) }
        integrity.failReads = true
        server.handleAuthRequest(.init(credentialId: "fixture", credentialLabel: "ignored",
            fieldNames: [], sessionId: nil, sessionLabel: nil, pid: 0), clientFd: pair.0, callerIdentity: caller)
        guard case .auth(let reply) = try response(pair.1) else { return XCTFail("wrong response") }
        XCTAssertFalse(reply.granted)
        XCTAssertNil(server.pendingRequest)
        XCTAssertEqual(server.waitingCount, 0)
        XCTAssertTrue(try approvals.all().isEmpty)
    }

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

private final class AdmissionSession: SessionControlling, @unchecked Sendable {
    var isVaultInitialized = true
    var reads = 0
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func unlock(passphrase: String) throws {}
    func lock() {}
    func retrieve(credentialId: String, fieldName: String) throws -> String {
        reads += 1
        return "synthetic-only"
    }
}
