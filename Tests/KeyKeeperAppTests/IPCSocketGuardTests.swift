import Foundation
import XCTest
@testable import KeyKeeperApp

final class IPCSocketGuardTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var socketPath: String!

    override func setUpWithError() throws {
        temporaryDirectory = URL(
            fileURLWithPath: "/tmp/kk-ipc-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        socketPath = temporaryDirectory.appendingPathComponent("server.sock").path

        let capabilityPath = temporaryDirectory.appendingPathComponent("capability.sock").path
        do {
            let fileDescriptor = try makeBoundSocket(at: capabilityPath, listening: false)
            close(fileDescriptor)
            unlink(capabilityPath)
        } catch let error as POSIXError where error.code == .EPERM {
            throw XCTSkip("execution sandbox does not permit binding Unix-domain sockets")
        }
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testMissingSocketBindsDirectly() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))

        let acquisition = try IPCSocketGuard.acquire(path: socketPath)
        guard case .acquired(let listener, .freshSocket) = acquisition else {
            return XCTFail("expected a fresh socket acquisition")
        }
        defer { listener.close() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(canConnect(to: socketPath))
    }

    func testStaleSocketIsRemovedAndRebound() throws {
        let staleFileDescriptor = try makeBoundSocket(at: socketPath, listening: false)
        close(staleFileDescriptor)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        let acquisition = try IPCSocketGuard.acquire(path: socketPath)
        guard case .acquired(let listener, .replacedStaleSocket) = acquisition else {
            return XCTFail("expected stale socket takeover")
        }
        defer { listener.close() }

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(canConnect(to: socketPath))
    }

    func testHealthySocketTriggersGuardWithoutUnlinkingIt() throws {
        let existingFileDescriptor = try makeBoundSocket(at: socketPath, listening: true)
        defer {
            close(existingFileDescriptor)
            unlink(socketPath)
        }
        let originalIdentity = try fileIdentity(at: socketPath)

        let acquisition = try IPCSocketGuard.acquire(path: socketPath)

        guard case .anotherInstanceRunning = acquisition else {
            return XCTFail("expected the existing-instance guard")
        }
        XCTAssertEqual(try fileIdentity(at: socketPath), originalIdentity)
        XCTAssertTrue(canConnect(to: socketPath))
    }

    func testClosingListenerClosesDescriptorAndRemovesOwnedSocket() throws {
        let acquisition = try IPCSocketGuard.acquire(path: socketPath)
        guard case .acquired(let listener, _) = acquisition else {
            return XCTFail("expected socket acquisition")
        }
        let fileDescriptor = listener.fileDescriptor

        listener.close()

        let descriptorCheck = fcntl(fileDescriptor, F_GETFD)
        let descriptorError = errno
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertEqual(descriptorCheck, -1)
        XCTAssertEqual(descriptorError, EBADF)
    }

    func testClosingOldListenerDoesNotRemoveReplacementSocket() throws {
        let acquisition = try IPCSocketGuard.acquire(path: socketPath)
        guard case .acquired(let oldListener, _) = acquisition else {
            return XCTFail("expected socket acquisition")
        }

        XCTAssertEqual(unlink(socketPath), 0)
        let replacementFileDescriptor = try makeBoundSocket(at: socketPath, listening: true)
        defer {
            close(replacementFileDescriptor)
            unlink(socketPath)
        }

        oldListener.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(canConnect(to: socketPath))
    }

    private func makeBoundSocket(at path: String, listening: Bool) throws -> Int32 {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        do {
            var address = try socketAddress(for: path)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                    Darwin.bind(
                        fileDescriptor,
                        socketPointer,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            if listening {
                guard Darwin.listen(fileDescriptor, 5) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
            return fileDescriptor
        } catch {
            close(fileDescriptor)
            throw error
        }
    }

    private func canConnect(to path: String) -> Bool {
        let fileDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }
        guard var address = try? socketAddress(for: path) else { return false }

        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.connect(
                    fileDescriptor,
                    socketPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        } == 0
    }

    private func socketAddress(for path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutablePointer(to: &address.sun_path) { sunPathPointer in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(sunPathPointer).copyMemory(
                    from: source.baseAddress!,
                    byteCount: source.count
                )
            }
        }
        return address
    }

    private func fileIdentity(at path: String) throws -> FileIdentity {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return FileIdentity(device: metadata.st_dev, inode: metadata.st_ino)
    }
}

final class IPCSocketTakeoverPolicyTests: XCTestCase {
    func testMissingSocketChoosesFreshBind() {
        XCTAssertEqual(
            IPCSocketTakeoverPolicy.decide(for: .missing),
            .bindFreshSocket
        )
    }

    func testSuccessfulConnectionChoosesExistingInstanceGuard() {
        XCTAssertEqual(
            IPCSocketTakeoverPolicy.decide(for: .connected),
            .reportAnotherInstance
        )
    }

    func testRefusedConnectionToUnchangedSocketChoosesTakeover() {
        XCTAssertEqual(
            IPCSocketTakeoverPolicy.decide(
                for: .connectionRefused(nodeIsSocket: true, nodeIsUnchanged: true)
            ),
            .replaceStaleSocket
        )
    }

    func testRefusedConnectionNeverReplacesNonSocketOrChangedNode() {
        XCTAssertEqual(
            IPCSocketTakeoverPolicy.decide(
                for: .connectionRefused(nodeIsSocket: false, nodeIsUnchanged: true)
            ),
            .refuseReplacement
        )
        XCTAssertEqual(
            IPCSocketTakeoverPolicy.decide(
                for: .connectionRefused(nodeIsSocket: true, nodeIsUnchanged: false)
            ),
            .refuseReplacement
        )
    }
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}
