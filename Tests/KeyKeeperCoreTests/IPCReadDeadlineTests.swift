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
