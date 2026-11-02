#if KEYKEEPER_SYNC_ACCEPTANCE
import XCTest
import Foundation
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class CloudSyncAcceptanceStoresTests: XCTestCase {
    func testFreshStoresUseIsolatedRealTransactionAndDurableStateSeams() throws {
        let run = UUID(), client = UUID(), directory = try makeDirectory(run, client)
        let io = AcceptanceMemoryIO()
        let stores = try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {})
        let before = try stores.local.capture()
        XCTAssertTrue(before.snapshot.credentials.isEmpty)
        XCTAssertNil(try stores.stateStore.load())
        XCTAssertTrue(try stores.approvals.all().isEmpty)
        let bundle = CloudCredentialBundle(metadata: Credential(label: "Synthetic", notes: "one", links: [],
            fields: ["key": .init(secret: true)], security: .strict, created: "now", updated: "now"),
            secrets: ["key": "synthetic-only"])
        _ = try stores.local.apply(.init(credentials: ["fixture": bundle]), expectedRevision: before.revision)
        try stores.stateStore.save(.init())
        let expected = try stores.local.capture().snapshot.encoded()
        let writes = io.items.values.reduce(0) { $0 + $1.writes }
        let reopened = try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: false,
            ioFactory: io.make, verifyIdentity: {})
        XCTAssertEqual(try reopened.local.capture().snapshot.encoded(), expected)
        XCTAssertEqual(try reopened.stateStore.load()?.enabled, false)
        XCTAssertEqual(io.items.values.reduce(0) { $0 + $1.writes }, writes)
        XCTAssertEqual(io.items.count, 5)
        XCTAssertTrue(io.items.keys.allSatisfy { $0.hasPrefix("dev.keykeeper.test.product-sync.\(run.uuidString).\(client.uuidString).") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path))
    }

    func testMissingUnsafeOrAliasedDirectoryRefusesBeforeIdentityAndIO() throws {
        let run = UUID(), client = UUID(), io = AcceptanceMemoryIO()
        var identityCalls = 0
        func open() throws {
            _ = try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
                ioFactory: io.make, verifyIdentity: { identityCalls += 1 })
        }
        XCTAssertThrowsError(try open())
        let directory = try makeDirectory(run, client)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        XCTAssertThrowsError(try open())
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let target = try makeDirectory(UUID(), UUID())
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        XCTAssertThrowsError(try open())
        XCTAssertEqual(identityCalls, 0)
        XCTAssertTrue(io.items.isEmpty)
    }

    func testAliasedMetadataAndRejectedIdentityNeverReachKeychainIO() throws {
        let run = UUID(), client = UUID(), directory = try makeDirectory(run, client), io = AcceptanceMemoryIO()
        var checked = false
        XCTAssertThrowsError(try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: { checked = true; throw CloudSyncError.setupRequired }))
        XCTAssertTrue(checked)
        XCTAssertTrue(io.items.isEmpty)
        let target = directory.appendingPathComponent("synthetic-target")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("meta.json"), withDestinationURL: target)
        XCTAssertThrowsError(try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: { XCTFail("Aliased file must fail before signature check") }))
        XCTAssertTrue(io.items.isEmpty)
    }

    func testPartialBootstrapCannotBeReclassifiedAsFresh() throws {
        let run = UUID(), client = UUID(), directory = try makeDirectory(run, client), io = AcceptanceMemoryIO()
        let service = "dev.keykeeper.test.product-sync.\(run.uuidString).\(client.uuidString).values"
        (io.make(service) as! FakeKeychainIO).failWrites = true
        XCTAssertThrowsError(try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {}))
        let metadata = try Data(contentsOf: directory.appendingPathComponent("meta.json"))
        let writes = io.items.values.reduce(0) { $0 + $1.writes }
        io.items[service]?.failWrites = false
        XCTAssertThrowsError(try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {}))
        XCTAssertEqual(io.items.values.reduce(0) { $0 + $1.writes }, writes)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("meta.json")), metadata)
    }

    func testClientsUseDistinctLocalStoresAndGrantsStayLocal() throws {
        let run = UUID(), a = UUID(), b = UUID(), io = AcceptanceMemoryIO()
        _ = try makeDirectory(run, a); _ = try makeDirectory(run, b)
        let first = try CloudSyncAcceptanceStores.open(runID: run, clientID: a, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {})
        let second = try CloudSyncAcceptanceStores.open(runID: run, clientID: b, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {})
        let snapshot = try syntheticSnapshot()
        _ = try first.local.apply(snapshot, expectedRevision: first.local.capture().revision)
        try first.approvals.add(.init(subject: .init(fingerprint: "synthetic-only", displayName: "Synthetic"),
            target: .credential(id: "fixture", fields: nil), duration: .always))
        XCTAssertEqual(try first.approvals.all().count, 1)
        XCTAssertTrue(try second.local.capture().snapshot.credentials.isEmpty)
        _ = try second.local.apply(first.local.capture().snapshot, expectedRevision: second.local.capture().revision)
        XCTAssertTrue(try second.approvals.all().isEmpty)
        XCTAssertEqual(try first.approvals.all().count, 1)
        XCTAssertEqual(io.items.count, 10)
    }

    func testReopeningPendingTransactionDoesNotRecoverUntilExplicitRequest() throws {
        let run = UUID(), client = UUID(), io = AcceptanceMemoryIO()
        _ = try makeDirectory(run, client)
        let stores = try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: true,
            ioFactory: io.make, verifyIdentity: {})
        let service = "dev.keykeeper.test.product-sync.\(run.uuidString).\(client.uuidString).values"
        io.items[service]?.failWrites = true
        let before = try stores.local.capture(), desired = try syntheticSnapshot()
        XCTAssertThrowsError(try stores.local.apply(desired, expectedRevision: before.revision))
        io.items[service]?.failWrites = false
        let writes = io.items.values.reduce(0) { $0 + $1.writes }
        let reopened = try CloudSyncAcceptanceStores.open(runID: run, clientID: client, initializeIfAbsent: false,
            ioFactory: io.make, verifyIdentity: {})
        XCTAssertEqual(io.items.values.reduce(0) { $0 + $1.writes }, writes)
        XCTAssertThrowsError(try reopened.local.capture())
        _ = try reopened.local.recover()
        XCTAssertEqual(try reopened.local.capture().snapshot.encoded(), try desired.encoded())
    }

    private func syntheticSnapshot() throws -> CloudVaultSnapshot {
        try .init(credentials: ["fixture": .init(metadata: .init(label: "Synthetic", notes: "one", links: [],
            fields: ["key": .init(secret: true)], security: .strict, created: "now", updated: "now"),
            secrets: ["key": "synthetic-only"])])
    }

    private func makeDirectory(_ run: UUID, _ client: UUID) throws -> URL {
        let directory = URL(fileURLWithPath: "/private/tmp/keykeeper-product-sync-\(run.uuidString)-\(client.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class AcceptanceMemoryIO {
    var items: [String: FakeKeychainIO] = [:]
    func make(_ service: String) -> KeychainBlobIO {
        if let existing = items[service] { return existing }
        let io = FakeKeychainIO(service: service); items[service] = io; return io
    }
}
#endif
