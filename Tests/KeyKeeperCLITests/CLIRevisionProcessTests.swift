import Darwin
import Foundation
import XCTest
import KeyKeeperCore
@testable import KeyKeeperCLI

final class CLIRevisionProcessTests: XCTestCase {
    private func snapshot(fields: [String: CredentialField] = ["key": .init(secret: true)],
                          security: SecurityLevel = .standard) throws -> VaultSnapshotResponse {
        let metadata = MetaFile(credentials: ["svc": .init(label: "App fixture", notes: "", links: [],
            fields: fields, security: security, created: "", updated: "", aliases: ["old-svc"])])
        return .init(success: true, metadata: metadata,
            revision: .init(instanceID: UUID(), epoch: 7, metadataDigest: try VaultRevision.metadataDigest(for: metadata)),
            valueInventory: ["svc": fields.filter(\.value.secret).keys.sorted()])
    }

    /// 【曾经的 bug】旧 App 无法提供版本快照时，CLI 仍从磁盘打印未经准入的元数据。
    func testOldAppCannotMakeListFallBackToRawMetadata() throws {
        let fixture = try RevisionSocketFixture { _, _ in
            .value(.init(success: false, error: "Unsupported request", errorCode: .invalidRequest))
        }
        defer { fixture.close() }
        let result = try fixture.run(["list"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertFalse(result.output.contains("disk-only"))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot"])
    }

    func testMutatingMigrationIsRetiredBeforeAnySocketOrStorageWork() throws {
        let fixture = try RevisionSocketFixture { _, _ in
            XCTFail("Retired migration must not contact the App")
            return .value(.init(success: false, errorCode: .invalidRequest))
        }
        defer { fixture.close() }
        // No secret fields are present, so even the pre-fix command cannot touch Keychain.
        for arguments in [["migrate-storage"], ["migrate-storage", "--delete-legacy"],
                          ["migrate-storage", "--dry-run", "--delete-legacy"]] {
            let result = try fixture.run(arguments)
            XCTAssertNotEqual(result.code, 0)
            XCTAssertTrue(result.error.contains("retired"))
            XCTAssertTrue(result.output.isEmpty)
        }
        XCTAssertTrue(fixture.requestTypes.isEmpty)
    }

    func testReadOnlyCommandsUseOneAppSnapshotAndNeverDiskMetadata() throws {
        let response = try snapshot(fields: ["key": .init(secret: true), "region": .init(value: "synthetic-region", secret: false)])
        let fixture = try RevisionSocketFixture { request, _ in
            XCTAssertEqual(request.type, "vaultSnapshot")
            return .vaultSnapshot(response)
        }
        defer { fixture.close() }
        for arguments in [["list", "--detail"], ["meta", "old-svc"], ["run", "-c", "svc", "--plan"],
                          ["status", "--check-values"], ["migrate-storage", "--dry-run"]] {
            let result = try fixture.run(arguments)
            XCTAssertEqual(result.code, 0, result.error)
            XCTAssertFalse(result.output.contains("disk-only"))
            XCTAssertFalse(result.output.isEmpty)
        }
        XCTAssertEqual(fixture.requestTypes, Array(repeating: "vaultSnapshot", count: 5))
        XCTAssertEqual(fixture.requests.map { $0.data?.inspectValues }, [false, true, true, true, false])
    }

    func testPlainGetUsesSnapshotValueWithoutASecondIntegrityQuery() throws {
        let response = try snapshot(fields: ["region": .init(value: "synthetic-region", secret: false)])
        let fixture = try RevisionSocketFixture { _, _ in .vaultSnapshot(response) }
        defer { fixture.close() }
        let result = try fixture.run(["get", "old-svc", "region"])
        XCTAssertEqual(result.code, 0, result.error)
        XCTAssertEqual(result.output, "synthetic-region")
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot"])
    }

    func testStaleGetReturnsNoValueAndDoesNotRequestApprovalOrRenewSnapshot() throws {
        let response = try snapshot(security: .strict)
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.type, "revisionValue")
            XCTAssertEqual(request.data?.revision, response.revision)
            return .value(.init(success: false, errorCode: .noAuthorization, revisionError: .stale))
        }
        defer { fixture.close() }
        let result = try fixture.run(["get", "svc", "key"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.error.contains("changed"))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue"])
    }

    func testStrictAuthorizationAndRereadRetainTheOriginalRevision() throws {
        let response = try snapshot(security: .strict)
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.data?.revision, response.revision)
            switch index {
            case 2: return .value(.init(success: false, errorCode: .noAuthorization))
            case 3: return .auth(.init(granted: true))
            case 4: return .value(.init(success: true, value: "synthetic-value"))
            default: XCTFail("Unexpected retry"); return .value(.init(success: false))
            }
        }
        defer { fixture.close() }
        let result = try fixture.run(["get", "svc", "key"])
        XCTAssertEqual(result.code, 0, result.error)
        XCTAssertEqual(result.output, "synthetic-value")
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue", "revisionAuth", "revisionValue"])
    }

    func testStaleAuthorizationNeverRereadsOrRenewsSnapshot() throws {
        let response = try snapshot(security: .strict)
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.data?.revision, response.revision)
            if index == 2 { return .value(.init(success: false, errorCode: .noAuthorization)) }
            return .auth(.init(granted: false, revisionError: .stale))
        }
        defer { fixture.close() }
        let result = try fixture.run(["get", "svc", "key"])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertTrue(result.output.isEmpty)
        XCTAssertTrue(result.error.contains("changed"))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue", "revisionAuth"])
    }

    /// 第一字段确实落成文件后第二字段变更；必须清理文件，且不能启动业务进程。
    func testRevisionChangeBetweenFieldsCleansMaterializedFileAndStartsNoChild() throws {
        let response = try snapshot(fields: ["a-json": .init(secret: true, fileFormat: .serviceAccountJSON),
                                             "z-token": .init(secret: true)])
        let root = try CredentialFileLease.root()
        let originalNames = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let observed = LeaseObservation()
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.type, "revisionValue")
            XCTAssertEqual(request.data?.revision, response.revision)
            if request.data?.fieldName == "a-json" {
                return .value(.init(success: true, value: Self.fileValue))
            }
            let names = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            observed.record(names.subtracting(originalNames).filter {
                FileManager.default.fileExists(atPath: root.appendingPathComponent($0).appendingPathComponent("credential-0.json").path)
            })
            return .value(.init(success: false, errorCode: .keychainError, revisionError: .stale))
        }
        defer { fixture.close() }
        let marker = fixture.directory.appendingPathComponent("child-started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let result = try fixture.run(["run", "-c", "svc", "--file", "svc:a-json=FIXTURE_JSON", "--", "/usr/bin/touch", marker.path])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(observed.names.isEmpty, "The first field must create a real file before the stale second read")
        for name in observed.names {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
        XCTAssertFalse((result.output + result.error).contains("synthetic-private-key"))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue", "revisionValue"])
    }

    func testSuccessfulFileRunUsesSnapshotPlainFieldAndRemovesTheFile() throws {
        let response = try snapshot(fields: ["json": .init(secret: true, fileFormat: .serviceAccountJSON),
                                             "region": .init(value: "synthetic-region", secret: false)])
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.data?.revision, response.revision)
            return .value(.init(success: true, value: Self.fileValue))
        }
        defer { fixture.close() }
        let result = try fixture.run(["run", "-c", "svc", "--file", "svc:json=FIXTURE_JSON", "--", "/bin/sh", "-c",
            "test -f \"$FIXTURE_JSON\" && test \"$REGION\" = synthetic-region && printf '%s' \"$FIXTURE_JSON\""])
        XCTAssertEqual(result.code, 0, result.error)
        XCTAssertTrue(result.output.hasSuffix("/credential-0.json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.output))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue"])
    }

    func testDifferentCredentialsShareOneRevisionAndStaleRunStartsNoChild() throws {
        var response = try snapshot()
        var metadata = try XCTUnwrap(response.metadata)
        metadata.credentials["other"] = .init(label: "Second fixture", notes: "", links: [],
            fields: ["other-key": .init(secret: true)], security: .standard, created: "", updated: "")
        response.metadata = metadata
        response.revision?.metadataDigest = try VaultRevision.metadataDigest(for: metadata)
        let fixture = try RevisionSocketFixture { request, index in
            if index == 1 { return .vaultSnapshot(response) }
            XCTAssertEqual(request.data?.revision, response.revision)
            if request.data?.credentialId == "svc" { return .value(.init(success: true, value: "synthetic-first-value")) }
            return .value(.init(success: false, revisionError: .stale))
        }
        defer { fixture.close() }
        let marker = fixture.directory.appendingPathComponent("child-started")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let result = try fixture.run(["run", "-c", "svc", "-c", "other", "--", "/usr/bin/touch", marker.path])
        XCTAssertNotEqual(result.code, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse((result.output + result.error).contains("synthetic-first-value"))
        XCTAssertEqual(fixture.requestTypes, ["vaultSnapshot", "revisionValue", "revisionValue"])
        XCTAssertEqual(fixture.requests.dropFirst().map { $0.data?.credentialId }, ["svc", "other"])
    }

    private static let fileValue = #"{"type":"service_account","client_email":"fixture@example.invalid","private_key":"synthetic-private-key"}"#
}

private final class LeaseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Set<String> = []
    var names: Set<String> { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ names: Set<String>) { lock.lock(); defer { lock.unlock() }; stored = names }
}

/// A real CLI process and Unix socket, with synthetic metadata and no App or Keychain IO.
private final class RevisionSocketFixture: @unchecked Sendable {
    struct Request: Decodable {
        let type: String
        let data: Body?
        struct Body: Decodable {
            let inspectValues: Bool?
            let credentialId: String?
            let fieldName: String?
            let revision: VaultRevision?
        }
    }
    struct Result {
        let code: Int32
        let output: String
        let error: String
    }
    let directory: URL
    private let socketName: String
    private let listener: Int32
    private let worker = DispatchGroup()
    private let lock = NSLock()
    private var stopping = false
    private var recorded: [Request] = []
    private var closed = false

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }
    var requestTypes: [String] { requests.map(\.type) }

    init(reply: @escaping (Request, Int) -> IPCResponse) throws {
        let identifier = UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-revision-\(identifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MetaStore(directory: directory).save(MetaFile(credentials: ["disk-only": .init(
            label: "Disk fixture", notes: "", links: [], fields: [:], security: .standard,
            created: "", updated: "")]))
        socketName = "/tmp/keykeeper-test-\(identifier).sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw IPCError.connectionFailed }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketName.utf8) + [0]
        withUnsafeMutablePointer(to: &address.sun_path) { target in
            bytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(target).copyMemory(from: source.baseAddress!, byteCount: bytes.count)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw IPCError.connectionFailed }
        worker.enter()
        DispatchQueue(label: "test.cli-revision-socket").async { [self] in
            defer { worker.leave() }
            while true {
                lock.lock(); let end = stopping; lock.unlock()
                if end { return }
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 100) > 0 else { continue }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { continue }
                defer { Darwin.close(client) }
                _ = fcntl(client, F_SETNOSIGPIPE, 1)
                guard let request = IPCMessage.readMessage(fd: client, as: Request.self, deadline: 1) else { continue }
                lock.lock(); recorded.append(request); let index = recorded.count; lock.unlock()
                try? IPCMessage.writeMessage(fd: client, message: reply(request, index), deadline: 1)
            }
        }
    }

    func run(_ arguments: [String]) throws -> Result {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = repo.appendingPathComponent(".build/debug/keykeeper")
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["KEYKEEPER_DATA_DIR"] = directory.path
        environment["KEYKEEPER_TEST_SOCKET"] = socketName
        environment["KEYKEEPER_KEYCHAIN_SERVICE"] = "com.keykeeper.test.cli-revision-\(directory.lastPathComponent)"
        process.environment = environment
        let output = Pipe(), error = Pipe()
        process.standardOutput = output; process.standardError = error
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(6)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            XCTFail("Synthetic CLI did not exit before its deadline")
        }
        process.waitUntilExit()
        return Result(code: process.terminationStatus,
            output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            error: String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    func close() {
        guard !closed else { return }; closed = true
        lock.lock(); stopping = true; lock.unlock()
        _ = worker.wait(timeout: .now() + 2)
        Darwin.close(listener)
        _ = unlink(socketName)
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}
