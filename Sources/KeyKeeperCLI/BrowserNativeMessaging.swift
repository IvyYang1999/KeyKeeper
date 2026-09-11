import Foundation
import Darwin
import KeyKeeperCore

enum BrowserNativeMessaging {
    static func read(fd: Int32, timeout: TimeInterval = 10) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let header = try readExactly(fd: fd, count: 4, deadline: deadline)
        var size: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &size) { header.copyBytes(to: $0) }
        guard size > 0, size <= BrowserSessionImport.maximumBytes else { throw BrowserSessionError.invalidImport }
        return try readExactly(fd: fd, count: Int(size), deadline: deadline)
    }
    private static func readExactly(fd: Int32, count: Int, deadline: TimeInterval) throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw BrowserSessionError.expired }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 10_000)))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { throw BrowserSessionError.disconnected }
            var buffer = [UInt8](repeating: 0, count: min(count - result.count, 8192))
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size > 0 else { throw BrowserSessionError.disconnected }
            result.append(contentsOf: buffer.prefix(size))
        }
        return result
    }
    static func write(_ response: BrowserSessionResponse, fd: Int32, timeout: TimeInterval = 5) throws {
        let bytes = try JSONEncoder().encode(response)
        guard bytes.count <= BrowserSessionImport.maximumBytes else { throw BrowserSessionError.capacity }
        var size = UInt32(bytes.count)
        var framed = withUnsafeBytes(of: &size) { Data($0) }; framed.append(bytes)
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw BrowserSessionError.unavailable }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try framed.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw BrowserSessionError.expired }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let remaining = max(1, min(1000, (deadline - ProcessInfo.processInfo.systemUptime) * 1000))
                let ready = poll(&descriptor, 1, Int32(remaining))
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw BrowserSessionError.disconnected }
                let written = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard written > 0 else { throw BrowserSessionError.disconnected }
                offset += written
            }
        }
    }
}
