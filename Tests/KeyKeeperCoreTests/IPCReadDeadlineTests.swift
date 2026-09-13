import XCTest
@testable import KeyKeeperCore

/// 【安全审计 2026-09-13】服务端的请求处理跑在一条串行队列上，而每次 read 的超时是 5 秒
/// ——**每次**。一个每 4.9 秒吐一个字节的连接可以无限期地把这条队列占住，连已经批准的
/// 请求的回包都发不出去。这就是 slowloris。
///
/// 修法不是重构并发模型（那是这个组件里风险最高的改动），而是给「读完一条消息」这件事
/// 加一个总时限：不管对方怎么滴水，一条消息最多占住这么久。
final class IPCReadDeadlineTests: XCTestCase {
    func test滴水式发送会在总时限内被放弃() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = fds[0], writer = fds[1]
        defer { close(reader); close(writer) }

        // 声称有 64 字节，然后只给 1 个，剩下的永远不给
        var header = UInt32(64).bigEndian
        _ = withUnsafeBytes(of: &header) { write(writer, $0.baseAddress!, 4) }
        var one: UInt8 = 0x7B
        _ = write(writer, &one, 1)

        let started = Date()
        let message = IPCMessage.readMessage(fd: reader, as: IPCRequest.self, deadline: 0.4)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNil(message, "读不完整就该放弃")
        XCTAssertLessThan(elapsed, 3.0, "超过总时限还在等，队列就被占住了：\(elapsed)s")
    }

    /// 正常的一条消息不该被时限误伤。
    func test完整的消息照常读出来() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let reader = fds[0], writer = fds[1]
        defer { close(reader); close(writer) }

        try IPCMessage.writeMessage(fd: writer, message: IPCRequest.serviceRequests(ServiceRequestsListRequest()))
        let message = IPCMessage.readMessage(fd: reader, as: IPCRequest.self, deadline: 5)
        guard case .serviceRequests = try XCTUnwrap(message) else { return XCTFail("解出来的类型不对") }
    }
}

/// 【曾经的 bug · 独立审计 2026-09-13 定为 critical】15 秒总时限一度是 readMessage 的**默认值**，
/// 于是命令行等批准回包也受它限制——而授权窗常常开着超过 15 秒。结果是每一条需要人点头
/// 的命令，都在人还在读弹窗的时候就失败了。时限只属于服务端读请求这一处。
final class IPCDeadlineScopeTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func test命令行等回包不带时限() throws {
        let client = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperCLI/IPCClient.swift"), encoding: .utf8)
        XCTAssertFalse(client.contains("deadline:"), "命令行要能等人读完弹窗")
    }

    func test服务端读请求带时限() throws {
        let server = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/IPCServer.swift"), encoding: .utf8)
        XCTAssertTrue(server.contains("deadline: IPCMessage.messageDeadline"))
    }

    /// 默认不带时限：发得慢但发得完的对端照样读得到。
    func test默认读取不设时限() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        let writer = fds[1]
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            try? IPCMessage.writeMessage(fd: writer, message: IPCRequest.serviceRequests(ServiceRequestsListRequest()))
        }
        XCTAssertNotNil(IPCMessage.readMessage(fd: fds[0], as: IPCRequest.self))
    }
}
