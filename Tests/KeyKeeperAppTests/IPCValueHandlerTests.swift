import Darwin
import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class IPCValueHandlerTests: XCTestCase {
    private var directory: URL!
    private var metaStore: MetaStore!
    private var grantStore: GrantStore!
    private var serviceGrantStore: ServiceGrantStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-ipc-value-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        metaStore = MetaStore(directory: directory)
        grantStore = GrantStore(directory: directory)
        serviceGrantStore = ServiceGrantStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testLockedValueRequestRejectsBeforeGrantOrPendingAuthorization() throws {
        try saveMetadata(security: .standard)
        try serviceGrantStore.setAuthorizationMode(.enforced)
        let session = FakeValueSession(status: .locked, result: .success("unused"))
        let server = makeServer(session: session)

        let response = try requestValue(server: server)

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.errorCode, .keychainError)
        XCTAssertEqual(response.storageErrorCode, .vaultLocked)
        XCTAssertEqual(session.retrieveCount, 0)
        XCTAssertNil(server.pendingRequest)
        XCTAssertNil(server.pendingServiceRequest)
        XCTAssertTrue(try serviceGrantStore.auditEvents().isEmpty)
    }

    func testLockedStrictValueRequestRejectsBeforeGrantValidation() throws {
        try saveMetadata(security: .strict)
        let session = FakeValueSession(status: .locked, result: .success("unused"))
        let server = makeServer(session: session)

        let response = try requestValue(server: server)

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.storageErrorCode, .vaultLocked)
        XCTAssertEqual(session.retrieveCount, 0)
        XCTAssertNil(server.pendingRequest)
        XCTAssertNil(server.pendingServiceRequest)
    }

    func testKeychainServiceReadsValueRoundTrip() throws {
        try saveMetadata(security: .standard)
        let service = KeychainCredentialService(store: KeychainBlobStore(io: MemoryBlobIO()))
        try service.save(
            credentialId: "service-a",
            fieldName: "access",
            value: "opaque-keychain-value",
            security: .standard
        )
        let server = makeServer(session: service)

        let response = try requestValue(server: server)

        XCTAssertTrue(response.success)
        XCTAssertEqual(response.value, "opaque-keychain-value")
        XCTAssertNil(response.errorCode)
        XCTAssertNil(response.storageErrorCode)
    }

    func testVaultNotFoundKeepsLegacyCodeAndAllReadFailuresGetStorageMapping() throws {
        try saveMetadata(security: .standard)

        let notFoundSession = FakeValueSession(
            status: .unlocked(expiresAt: nil),
            result: .failure(KeychainError.notFound)
        )
        let notFound = try requestValue(server: makeServer(session: notFoundSession))
        XCTAssertFalse(notFound.success)
        XCTAssertEqual(notFound.errorCode, .notFound)
        XCTAssertEqual(notFound.storageErrorCode, .readFailed)

        let errors: [Error] = [
            KeychainError.unexpectedData,
            StorageTestError.timedOut,
        ]

        for error in errors {
            let session = FakeValueSession(
                status: .unlocked(expiresAt: nil),
                result: .failure(error)
            )
            let response = try requestValue(server: makeServer(session: session))

            XCTAssertFalse(response.success)
            XCTAssertEqual(response.errorCode, .keychainError)
            XCTAssertEqual(response.storageErrorCode, .readFailed)
            XCTAssertFalse(response.error?.contains("Keychain") ?? false)
        }
    }

    func testStrictOnceGrantIsConsumedOnlyAfterSuccessfulVaultRead() throws {
        try saveMetadata(security: .strict)
        let grant = Grant(
            id: "strict-once",
            credentialId: "service-a",
            duration: .once
        )
        try grantStore.addGrant(grant)
        let session = FakeValueSession(
            status: .unlocked(expiresAt: nil),
            result: .failure(StorageTestError.timedOut)
        )
        let server = makeServer(session: session)

        let failed = try requestValue(server: server)
        XCTAssertFalse(failed.success)
        XCTAssertFalse(try XCTUnwrap(grantStore.grants(for: "service-a").first).consumed)

        session.result = .success("opaque-success-value")
        let succeeded = try requestValue(server: server)
        XCTAssertTrue(succeeded.success)
        XCTAssertTrue(try XCTUnwrap(grantStore.grants(for: "service-a").first).consumed)
    }

    func testServiceOnceGrantRecordsUseOnlyAfterSuccessfulVaultRead() throws {
        try saveMetadata(security: .standard)
        let caller = makeCaller()
        let serviceGrant = ServiceGrant(
            id: "service-once",
            credentialId: "service-a",
            subjectFingerprint: caller.subjectFingerprint,
            subjectDisplayName: caller.displayName,
            fields: ["access"],
            duration: .once
        )
        try serviceGrantStore.addGrant(serviceGrant)
        let session = FakeValueSession(
            status: .unlocked(expiresAt: nil),
            result: .failure(StorageTestError.timedOut)
        )
        let server = makeServer(session: session)

        let failed = try requestValue(server: server, caller: caller)
        XCTAssertFalse(failed.success)
        XCTAssertEqual(try serviceGrantStore.grants().map(\.id), ["service-once"])

        session.result = .success("opaque-success-value")
        let succeeded = try requestValue(server: server, caller: caller)
        XCTAssertTrue(succeeded.success)
        XCTAssertTrue(try serviceGrantStore.grants().isEmpty)
    }

    func testLockWinningBetweenPrecheckAndRetrieveReturnsOnlyVaultLocked() throws {
        try saveMetadata(security: .standard)
        let session = FakeValueSession(
            status: .unlocked(expiresAt: nil),
            result: .failure(SessionManagerError.locked)
        )

        let response = try requestValue(server: makeServer(session: session))

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.errorCode, .keychainError)
        XCTAssertEqual(response.storageErrorCode, .vaultLocked)
        XCTAssertEqual(session.retrieveCount, 1)
    }

    private func makeServer(session: SessionControlling) -> IPCServer {
        IPCServer(
            session: session,
            metaStore: metaStore,
            grantStore: grantStore,
            serviceGrantStore: serviceGrantStore
        )
    }

    private func saveMetadata(security: SecurityLevel) throws {
        try metaStore.save(MetaFile(credentials: [
            "service-a": Credential(
                label: "Service A",
                notes: "",
                links: [],
                fields: ["access": CredentialField(secret: true)],
                security: security,
                created: "2026-07-20",
                updated: "2026-07-20"
            ),
        ]))
    }

    private func requestValue(
        server: IPCServer,
        caller: CallerIdentity? = nil
    ) throws -> ValueResponse {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptors[1]) }

        server.handleValueRequest(
            ValueRequest(
                credentialId: "service-a",
                fieldName: "access",
                sessionId: nil,
                requestedFieldNames: ["access"]
            ),
            clientFd: descriptors[0],
            callerIdentity: caller ?? makeCaller()
        )

        guard let envelope = IPCMessage.readMessage(fd: descriptors[1], as: IPCResponse.self),
              case .value(let response) = envelope else {
            throw IPCError.readFailed
        }
        return response
    }

    private func makeCaller() -> CallerIdentity {
        CallerIdentity(
            peerPID: 123,
            subject: CallerSubject(
                kind: .executable,
                fingerprint: "test:ipc-value-caller",
                displayName: "IPC value test",
                detail: "test fixture"
            )
        )
    }
}

private final class FakeValueSession: SessionControlling, @unchecked Sendable {
    var isVaultInitialized = true
    private let mutex = NSLock()
    private var currentStatus: SessionStatus
    private var currentResult: Result<String, Error>
    private var retrievals = 0

    init(status: SessionStatus, result: Result<String, Error>) {
        currentStatus = status
        currentResult = result
    }

    var result: Result<String, Error> {
        get { withLock { currentResult } }
        set { withLock { currentResult = newValue } }
    }

    var retrieveCount: Int { withLock { retrievals } }

    func status() -> SessionStatus { withLock { currentStatus } }

    func unlock(passphrase: String) throws {
        withLock { currentStatus = .unlocked(expiresAt: nil) }
    }

    func lock() {
        withLock { currentStatus = .locked }
    }

    func retrieve(credentialId: String, fieldName: String) throws -> String {
        try withLock {
            retrievals += 1
            return try currentResult.get()
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try operation()
    }
}

private enum StorageTestError: Error {
    case timedOut
}

private final class MemoryBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data) throws { blob = data }
}
