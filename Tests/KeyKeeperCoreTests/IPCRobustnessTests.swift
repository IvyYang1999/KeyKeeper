import XCTest
import Darwin
@testable import KeyKeeperCore

private struct BigMessage: Codable { let text: String }

private final class ReaderBox: @unchecked Sendable {
    var thread: pthread_t?
    var data: Data?
    var message: BigMessage?
    let ready = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
}

/// 【独立审计 2026-09-13】收发两侧还有两处会把正常消息弄丢：
/// 1. poll() 被信号打断（EINTR）时直接当成失败，整条消息丢掉——仓库里另一个分帧读取器是重试的。
/// 2. 设了发送超时的 socket 上，大消息会被分段写出；writeMessage 只写一次，写了一半就报失败，
///    而那一半字节已经发出去了。
final class IPCRobustnessTests: XCTestCase {
    func test读的时候被信号打断不丢消息() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var action = sigaction()
        action.__sigaction_u.__sa_handler = { _ in }
        action.sa_flags = 0
        var previous = sigaction()
        sigaction(SIGUSR2, &action, &previous)
        defer { sigaction(SIGUSR2, &previous, nil) }

        let reader = fds[0], writer = fds[1]
        let box = ReaderBox()
        Thread.detachNewThread {
            box.thread = pthread_self()
            box.ready.signal()
            box.data = IPCMessage.readExact(fd: reader, count: 4, deadline: Date().addingTimeInterval(5))
            box.done.signal()
        }
        box.ready.wait()
        usleep(200_000)                       // 让它进到 poll 里
        pthread_kill(try XCTUnwrap(box.thread), SIGUSR2)
        usleep(100_000)
        let bytes: [UInt8] = [1, 2, 3, 4]
        _ = bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, 4) }
        XCTAssertEqual(box.done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(box.data?.count, 4, "一个信号不该让整条消息作废")
    }

    func test发送超时下大消息分段写完() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var small: Int32 = 4096
        setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fds[1], SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let reader = fds[0]
        let box = ReaderBox()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            box.message = IPCMessage.readMessage(fd: reader, as: BigMessage.self)
            box.done.signal()
        }
        let text = String(repeating: "x", count: 300_000)
        XCTAssertNoThrow(try IPCMessage.writeMessage(fd: fds[1], message: BigMessage(text: text)))
        XCTAssertEqual(box.done.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(box.message?.text.count, text.count)
    }
}

extension IPCRobustnessTests {
    /// 对端一直不读，服务端的写也必须在时限内放弃，不能把串行队列占住。
    func test对端不读时写入在时限内放弃() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }
        var small: Int32 = 4096
        setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        let started = Date()
        XCTAssertThrowsError(try IPCMessage.writeMessage(fd: fds[1], message: BigMessage(text: String(repeating: "x", count: 300_000)),
                                                         deadline: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let flags = fcntl(fds[1], F_GETFL)
        XCTAssertEqual(flags & O_NONBLOCK, 0, "写完要把 socket 的阻塞模式还回去")
    }
}
