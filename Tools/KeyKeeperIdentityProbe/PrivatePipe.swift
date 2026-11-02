import Darwin
import Foundation

enum PrivatePipe {
    static let limit = 1_500_000
    static func ready(_ fd: Int32, events: Int16, until: UInt64) throws {
        guard DispatchTime.now().uptimeNanoseconds < until else { throw ProbeFailure.deadline }
        var descriptor = pollfd(fd: fd, events: events, revents: 0)
        let result = poll(&descriptor, 1, 50)
        guard result >= 0 || errno == EINTR else { throw ProbeFailure.io }
        guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else { throw ProbeFailure.io }
    }

    static func read(_ fd: Int32, until: UInt64) throws -> Data {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw ProbeFailure.io }
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            try ready(fd, events: Int16(POLLIN), until: until)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { return output }
            if count < 0 {
                guard errno == EAGAIN || errno == EINTR else { throw ProbeFailure.io }
                continue
            }
            guard output.count + count <= limit else { throw ProbeFailure.rejected }
            output.append(contentsOf: bytes.prefix(count))
        }
    }

    static func write(_ data: Data, fd: Int32, until: UInt64) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw ProbeFailure.io }
        var offset = 0
        while offset < data.count {
            try ready(fd, events: Int16(POLLOUT), until: until)
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            if count < 0 {
                guard errno == EAGAIN || errno == EINTR else { throw ProbeFailure.io }; continue
            }
            offset += count
        }
    }

    static func transfer(_ wire: Data, receiver: URL, context: ProbeContext) throws -> Data {
        try ProbeIdentity.receiver(receiver, team: context.team)
        let process = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = receiver
        process.arguments = context.childArguments
        // No ambient KeyKeeper override, user secret, or cloud variable reaches the child.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try process.run()
        input.fileHandleForReading.closeFile(); output.fileHandleForWriting.closeFile(); errors.fileHandleForWriting.closeFile()
        defer {
            input.fileHandleForWriting.closeFile(); output.fileHandleForReading.closeFile(); errors.fileHandleForReading.closeFile()
            if process.isRunning {
                process.terminate()
                if ended.wait(timeout: .now() + 1) == .timedOut {
                    _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 1)
                }
            }
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 15_000_000_000
        try write(wire, fd: input.fileHandleForWriting.fileDescriptor, until: deadline)
        input.fileHandleForWriting.closeFile()
        let result = try read(output.fileHandleForReading.fileDescriptor, until: deadline)
        let diagnostics = try read(errors.fileHandleForReading.fileDescriptor, until: deadline)
        guard ended.wait(timeout: DispatchTime(uptimeNanoseconds: deadline)) == .success else { throw ProbeFailure.deadline }
        guard process.terminationStatus == 0 else {
            ProbeDiagnostics.forwardReceiverFailure(diagnostics)
            throw ProbeFailure.rejected
        }
        return result
    }
}
