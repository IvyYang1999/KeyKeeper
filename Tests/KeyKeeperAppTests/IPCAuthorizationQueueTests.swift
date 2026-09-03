import Darwin
import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class IPCAuthorizationQueueTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var grantStore: GrantStore!
    private var serviceGrantStore: ServiceGrantStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-ipc-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        grantStore = GrantStore(directory: directory)
        serviceGrantStore = ServiceGrantStore(directory: directory)
        try metaStore.save(MetaFile(credentials: [
            "service-a": Credential(
                label: "Service A", notes: "", links: [],
                fields: ["access": CredentialField(secret: true)],
                security: .standard, created: "2026-09-03", updated: "2026-09-03"
            ),
        ]))
        try serviceGrantStore.setAuthorizationMode(.enforced)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 【曾经的 bug】已有授权窗时，第二个并发请求被立即拒绝，CLI 报「denied」而用户从未点过 Deny。
    func test曾经的Bug并发服务授权请求排队而不是被拒() throws {
        let server = makeServer()
        let first = try sendValueRequest(server: server, caller: makeCaller("one"))
        let second = try sendValueRequest(server: server, caller: makeCaller("two"))
        defer { close(first); close(second) }
        drainMainQueue()

        XCTAssertEqual(server.pendingServiceRequest?.callerIdentity.displayName, "caller one")
        XCTAssertEqual(server.waitingCount, 1)
        XCTAssertFalse(hasResponse(second), "queued request must not be answered yet")

        let pending = try XCTUnwrap(server.pendingServiceRequest)
        server.denyServiceRequest(pending)
        drainMainQueue()

        let firstResponse = try readValueResponse(first)
        XCTAssertEqual(firstResponse.errorCode, .authorizationDenied)
        XCTAssertEqual(server.pendingServiceRequest?.callerIdentity.displayName, "caller two")
        XCTAssertEqual(server.waitingCount, 0)

        let promoted = try XCTUnwrap(server.pendingServiceRequest)
        server.denyServiceRequest(promoted)
        drainMainQueue()
        XCTAssertEqual(try readValueResponse(second).errorCode, .authorizationDenied)
        XCTAssertNil(server.pendingServiceRequest)
    }

    func test超过队列上限才返回忙碌错误并指明原因() throws {
        let server = makeServer()
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for index in 0...(IPCServer.maximumWaiting) {
            descriptors.append(try sendValueRequest(server: server, caller: makeCaller("\(index)")))
        }
        drainMainQueue()
        XCTAssertEqual(server.waitingCount, IPCServer.maximumWaiting)

        let overflow = try sendValueRequest(server: server, caller: makeCaller("overflow"))
        descriptors.append(overflow)
        drainMainQueue()

        let response = try readValueResponse(overflow)
        XCTAssertFalse(response.success)
        XCTAssertEqual(response.error, IPCServer.busyMessage)
        XCTAssertTrue(response.error?.contains("retry") ?? false)
    }

    func test待处理列表包含排队中的请求() throws {
        let server = makeServer()
        let first = try sendValueRequest(server: server, caller: makeCaller("one"))
        let second = try sendValueRequest(server: server, caller: makeCaller("two"))
        defer { close(first); close(second) }
        drainMainQueue()

        XCTAssertEqual(server.pendingServiceRequest?.summary.callerDisplayName, "caller one")
        XCTAssertEqual(server.waitingCount, 1)
    }

    func test窗口标题显示排队数量() {
        XCTAssertEqual(AuthorizationWindowController.windowTitle(waiting: 0), "KeyKeeper Authorization")
        XCTAssertEqual(AuthorizationWindowController.windowTitle(waiting: 3), "KeyKeeper Authorization (3 more waiting)")
    }

    // MARK: - Helpers

    private func makeServer() -> IPCServer {
        IPCServer(
            session: QueueSession(),
            metaStore: metaStore,
            grantStore: grantStore,
            serviceGrantStore: serviceGrantStore
        )
    }

    /// Sends a value request and returns the client-side descriptor to read the response from.
    private func sendValueRequest(server: IPCServer, caller: CallerIdentity) throws -> Int32 {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        server.handleValueRequest(
            ValueRequest(credentialId: "service-a", fieldName: "access", sessionId: nil),
            clientFd: descriptors[0],
            callerIdentity: caller
        )
        return descriptors[1]
    }

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private func hasResponse(_ fd: Int32) -> Bool {
        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        return poll(&pollDescriptor, 1, 50) > 0
    }

    private func readValueResponse(_ fd: Int32) throws -> ValueResponse {
        guard let envelope = IPCMessage.readMessage(fd: fd, as: IPCResponse.self),
              case .value(let response) = envelope else {
            throw IPCError.readFailed
        }
        return response
    }

    private func makeCaller(_ name: String) -> CallerIdentity {
        CallerIdentity(
            peerPID: 123,
            subject: CallerSubject(
                kind: .executable,
                fingerprint: "test:queue-\(name)",
                displayName: "caller \(name)",
                detail: "test fixture"
            )
        )
    }
}

private final class QueueSession: SessionControlling, @unchecked Sendable {
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func unlock(passphrase: String) throws {}
    func lock() {}
    func retrieve(credentialId: String, fieldName: String) throws -> String { "opaque-value" }
}
