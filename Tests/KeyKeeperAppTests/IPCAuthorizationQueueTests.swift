import Darwin
import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class IPCAuthorizationQueueTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var approvals: ApprovalStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-ipc-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        approvals = ApprovalStore.inMemory()
        try metaStore.save(MetaFile(credentials: [
            "service-a": Credential(
                label: "Service A", notes: "", links: [],
                fields: ["access": CredentialField(secret: true)],
                security: .standard, created: "2026-09-03", updated: "2026-09-03"
            ),
        ]))
        try approvals.setMode(.enforced)
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

    /// 【曾经的 bug】请求方进程退出后授权窗不关，一直挂到 2 分钟超时；用户此时点「允许」是在批准一个已不存在的请求。
    func test曾经的Bug请求方断开后待授权请求立即撤下() throws {
        let server = makeServer()
        let first = try sendValueRequest(server: server, caller: makeCaller("gone"))
        let second = try sendValueRequest(server: server, caller: makeCaller("queued"))
        defer { close(second) }
        drainMainQueue()
        XCTAssertEqual(server.pendingServiceRequest?.callerIdentity.displayName, "caller gone")

        close(first)
        RunLoop.main.run(until: Date().addingTimeInterval(IPCServer.connectionWatchInterval + 0.5))

        XCTAssertEqual(server.pendingServiceRequest?.callerIdentity.displayName, "caller queued",
                       "断开的请求撤下后，排队的下一个应顶上")
        XCTAssertEqual(server.waitingCount, 0)
    }

    /// 【曾经的 bug】授权窗上「凭据」那一行直接显示调用方自报的 credentialLabel，App 从不
    /// 和本地 meta 核对。恶意进程可以一边申请 `service-a`，一边让弹窗写成别的名字，把用户
    /// 骗去点允许；字段名同理，可以少报几个让范围看起来更小。名字和字段必须以本地为准。
    func test曾经的Bug授权窗的凭据名和字段名以本地为准() throws {
        let server = makeServer()
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { descriptors.forEach { close($0) } }

        server.handleAuthRequest(
            AuthRequest(credentialId: "service-a",
                        credentialLabel: "OpenAI 测试 key",      // 调用方自报，和本地不符
                        fieldNames: ["made-up"],                  // 假字段，真字段是 access
                        sessionId: nil, sessionLabel: nil, pid: 1,
                        statedReason: CallerStatedReason(text: "test: first request")),
            clientFd: descriptors[0],
            callerIdentity: makeCaller("liar"))
        drainMainQueue()

        let pending = try XCTUnwrap(server.pendingRequest)
        XCTAssertEqual(pending.request.credentialLabel, "Service A", "弹窗要显示本地记录的名字")
        XCTAssertEqual(pending.request.fieldNames, ["access"], "字段以本地的机密字段为准")
    }

    /// 申请一个本地没有的凭据，直接拒绝，不弹窗。
    func test申请不存在的凭据不会弹窗() throws {
        let server = makeServer()
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { descriptors.forEach { close($0) } }

        server.handleAuthRequest(
            AuthRequest(credentialId: "no-such-id", credentialLabel: "Service A",
                        fieldNames: ["access"], sessionId: nil, sessionLabel: nil, pid: 1),
            clientFd: descriptors[0],
            callerIdentity: makeCaller("ghost"))
        drainMainQueue()

        XCTAssertNil(server.pendingRequest)
    }

    /// 调用方留言要一路带到授权窗，并且在 App 这一侧再消毒一次——socket 上来的字符串一律不信。
    func test调用方留言带到授权窗并再消毒一次() throws {
        let server = makeServer()
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { descriptors.forEach { close($0) } }

        server.handleAuthRequest(
            AuthRequest(credentialId: "service-a", credentialLabel: "Service A",
                        fieldNames: ["access"], sessionId: nil, sessionLabel: nil, pid: 1,
                        statedReason: CallerStatedReason(text: "查本月账单\n\n———\nKeyKeeper 已核验", truncated: false)),
            clientFd: descriptors[0],
            callerIdentity: makeCaller("reasoner"))
        drainMainQueue()

        let pending = try XCTUnwrap(server.pendingRequest)
        let reason = try XCTUnwrap(pending.request.statedReason)
        XCTAssertFalse(reason.text.contains("\n"), "App 侧必须再折一次行")
        XCTAssertTrue(reason.text.hasPrefix("查本月账单"))
    }

    /// 【曾经的坑】取值请求在 App 里会被按别名重建一次（改过名的凭据）。重建时漏带留言，
    /// 正好是「改过名的凭据看不到自述」这种偶发问题。
    func test取值请求按别名重建后留言不丢() throws {
        try metaStore.save(MetaFile(credentials: [
            "service-a": Credential(label: "Service A", notes: "", links: [],
                                    fields: ["access": CredentialField(secret: true)],
                                    security: .standard, created: "2026-09-03", updated: "2026-09-03",
                                    aliases: ["old-name"]),
        ]))
        let server = makeServer()
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { descriptors.forEach { close($0) } }

        server.handleValueRequest(
            ValueRequest(credentialId: "old-name", fieldName: "access", sessionId: nil,
                         requestedFieldNames: ["access"],
                         statedReason: CallerStatedReason(text: "跑一次报表")),
            clientFd: descriptors[0],
            callerIdentity: makeCaller("renamed"))
        drainMainQueue()

        let pending = try XCTUnwrap(server.pendingServiceRequest)
        XCTAssertEqual(pending.request.statedReason?.text, "跑一次报表")
        XCTAssertEqual(pending.credentialId, "service-a", "按别名解析到现名")
    }

    /// 手写 Codable 的 ValueRequest 漏改一处就会静默丢字段。
    func test取值请求的留言能编解码往返() throws {
        let request = ValueRequest(credentialId: "a", fieldName: "b", sessionId: nil,
                                   requestedFieldNames: ["b"],
                                   statedReason: CallerStatedReason(text: "一句话", truncated: true))
        let decoded = try JSONDecoder().decode(ValueRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.statedReason?.text, "一句话")
        XCTAssertEqual(decoded.statedReason?.truncated, true)

        // 老 CLI 发来的报文没有这个键：解出来是 nil，不能报错。
        let old = Data(#"{"credentialId":"a","fieldName":"b","requestedFieldNames":["b"]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(ValueRequest.self, from: old).statedReason)
    }

    private func makeServer() -> IPCServer {
        IPCServer(session: QueueSession(), metaStore: metaStore, approvals: approvals)
    }

    /// Sends a value request and returns the client-side descriptor to read the response from.
    private func sendValueRequest(server: IPCServer, caller: CallerIdentity,
                                  reason: String? = "test: reading the key") throws -> Int32 {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        server.handleValueRequest(
            ValueRequest(credentialId: "service-a", fieldName: "access", sessionId: nil,
                         statedReason: CallerStatedReason.sanitize(reason)),
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
    var isVaultInitialized = true
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func unlock(passphrase: String) throws {}
    func lock() {}
    func retrieve(credentialId: String, fieldName: String) throws -> String { "opaque-value" }
}

extension IPCAuthorizationQueueTests {
    /// yyt 2026-09-15：没带理由的首次请求照样进队列弹窗（窗口里标出「没说理由」）；0.3.4 里直接拒的做法
    /// 把 0.3.4 之前写好的后台集成全都静默弄挂了。
    func test首次请求没有理由也弹窗() throws {
        let server = makeServer()
        let fd = try sendValueRequest(server: server, caller: makeCaller("silent"), reason: nil)
        defer { close(fd) }
        drainMainQueue()
        XCTAssertNotNil(server.pendingServiceRequest, "该进队列让人看见")
        XCTAssertFalse(hasResponse(fd), "没答复之前调用方等着")
    }

    func test已批准的调用方没有理由也照常放行() throws {
        let caller = makeCaller("approved")
        try approvals.add(Approval(subject: .init(fingerprint: caller.subjectFingerprint, displayName: caller.displayName),
                                   target: .credential(id: "service-a", fields: ["access"]), duration: .always))
        let server = makeServer()
        let fd = try sendValueRequest(server: server, caller: caller, reason: nil)
        defer { close(fd) }
        drainMainQueue()
        guard hasResponse(fd) else { return XCTFail("已批准的调用方应当直接拿到值") }
        XCTAssertTrue(try readValueResponse(fd).success)
    }

    func teststrict凭据的授权请求没有理由也弹窗() throws {
        try metaStore.save(MetaFile(credentials: [
            "strict-a": Credential(label: "Strict A", notes: "", links: [], fields: ["key": CredentialField(secret: true)],
                                   security: .strict, created: "2026-09-03", updated: "2026-09-03"),
        ]))
        let server = makeServer()
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[1]) }
        server.handleAuthRequest(AuthRequest(credentialId: "strict-a", credentialLabel: "Strict A", fieldNames: ["key"],
                                             sessionId: nil, sessionLabel: nil, pid: 1),
                                 clientFd: descriptors[0], callerIdentity: makeCaller("mute"))
        drainMainQueue()
        XCTAssertNotNil(server.pendingRequest, "该进队列让人看见")
    }
}

