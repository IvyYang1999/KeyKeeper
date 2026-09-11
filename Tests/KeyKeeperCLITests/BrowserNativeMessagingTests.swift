import XCTest
import Foundation
import Darwin
import KeyKeeperCore
@testable import KeyKeeperCLI

final class BrowserNativeMessagingTests: XCTestCase {
    func testNativeFrameIsBoundedUTF8WithNativeEndianPrefixAndNoEcho() throws {
        let pipe = Pipe()
        let expected = BrowserSessionRequest(action: .list)
        let data = try JSONEncoder().encode(expected)
        var size = UInt32(data.count)
        var framed = withUnsafeBytes(of: &size) { Data($0) }; framed.append(data)
        try pipe.fileHandleForWriting.write(contentsOf: framed)
        let received = try BrowserNativeMessaging.read(fd: pipe.fileHandleForReading.fileDescriptor, timeout: 1)
        XCTAssertEqual(received, data)
        let output = Pipe()
        try BrowserNativeMessaging.write(.init(success: false, errorCode: .denied), fd: output.fileHandleForWriting.fileDescriptor)
        let response = try BrowserNativeMessaging.read(fd: output.fileHandleForReading.fileDescriptor, timeout: 1)
        XCTAssertFalse(String(decoding: response, as: UTF8.self).contains("snapshot"))
        XCTAssertEqual(try JSONDecoder().decode(BrowserSessionResponse.self, from: response).errorCode, .denied)
    }
    func testOversizedPartialAndClosedInputFailWithoutAllocationOrUnboundedWait() throws {
        for size: UInt32 in [0, 131_073, UInt32.max] {
            let pipe = Pipe(); var size = size
            try pipe.fileHandleForWriting.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
            XCTAssertThrowsError(try BrowserNativeMessaging.read(fd: pipe.fileHandleForReading.fileDescriptor, timeout: 0.01))
        }
        let pipe = Pipe(); try pipe.fileHandleForWriting.close()
        XCTAssertThrowsError(try BrowserNativeMessaging.read(fd: pipe.fileHandleForReading.fileDescriptor, timeout: 0.01))
    }
    func testNonReadingReceiverCannotBlockWritePastDeadline() throws {
        let pipe = Pipe(); let fd = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        XCTAssertEqual(fcntl(fd, F_SETFL, flags | O_NONBLOCK), 0)
        let buffer = [UInt8](repeating: 0, count: 4096)
        while Darwin.write(fd, buffer, buffer.count) > 0 {}
        XCTAssertEqual(fcntl(fd, F_SETFL, flags), 0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try BrowserNativeMessaging.write(.init(success: true), fd: fd, timeout: 0.03))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
        XCTAssertEqual(fcntl(fd, F_GETFL) & O_NONBLOCK, flags & O_NONBLOCK)
    }
}
