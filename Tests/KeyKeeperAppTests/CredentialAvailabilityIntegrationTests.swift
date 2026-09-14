import XCTest
import Foundation
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class CredentialAvailabilityIntegrationTests: XCTestCase {

    func testRealServiceIPCOnlyReturnsNamesWithoutReadingOnOrdinaryStatus() throws {
        let io = FakeKeychainIO()
        io.blob = Data(#"{"version":1,"credentials":{"fixture":{"field":"synthetic"}}}"#.utf8)
        let session = KeychainCredentialService(store: KeychainBlobStore(io: io))
        let server = IPCServer(session: session, approvals: .inMemory())
        XCTAssertNil(server.handleSessionControl(.init(action: .status)).valueInventory)
        let reply = server.handleSessionControl(.init(action: .status, inspectValues: true))
        XCTAssertEqual(reply.valueInventory, ["fixture": ["field"]])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(reply), as: UTF8.self).contains("synthetic"))
        io.readError = KeychainError.unexpectedData
        XCTAssertNil(server.handleSessionControl(.init(action: .status, inspectValues: true)).valueInventory)
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertEqual(io.writes, 0)
    }

    func testListRefreshShowsMissingThenPresentThenUnknownWithoutChangingMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = MetaStore(directory: directory)
        let record = Credential(label: "Fixture", notes: "", links: [],
            fields: ["field": .init(secret: true)], security: .standard,
            created: "2026-01-01", updated: "2026-01-01")
        try metadata.save(.init(credentials: ["fixture": record]))
        let before = try Data(contentsOf: metadata.fileURL)
        let io = FakeKeychainIO()
        let vm = CredentialListViewModel(session: KeychainCredentialService(store: KeychainBlobStore(io: io)), store: metadata)
        vm.load()
        try await finish(vm)
        XCTAssertEqual(vm.valueAvailability["fixture"]?.state, .missing)
        io.blob = Data(#"{"version":1,"credentials":{"fixture":{"field":"synthetic"}}}"#.utf8)
        vm.load()
        XCTAssertNil(vm.valueAvailability["fixture"])
        try await finish(vm)
        XCTAssertEqual(vm.valueAvailability["fixture"]?.state, .present)
        io.readError = KeychainError.unexpectedData
        vm.load()
        try await finish(vm)
        XCTAssertEqual(vm.valueAvailability["fixture"]?.state, .unavailable)
        XCTAssertEqual(try Data(contentsOf: metadata.fileURL), before)
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertEqual(io.writes, 0)
    }

    private func finish(_ vm: CredentialListViewModel) async throws {
        for _ in 0..<100 where vm.isCheckingValues { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(vm.isCheckingValues)
    }

    func testReloadsCoalesceAndDoNotPublishAStaleResult() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = MetaStore(directory: directory)
        let record = Credential(label: "Fixture", notes: "", links: [],
            fields: ["field": .init(secret: true)], security: .standard,
            created: "2026-01-01", updated: "2026-01-01")
        try metadata.save(.init(credentials: ["before": record]))
        let io = FakeKeychainIO()
        let gate = DispatchSemaphore(value: 0)
        let began = expectation(description: "inspection started")
        io.onRead = {
            if io.reads == 1 {
                began.fulfill()
                _ = gate.wait(timeout: .now() + 2)
            }
        }
        let vm = CredentialListViewModel(session: KeychainCredentialService(store: KeychainBlobStore(io: io)), store: metadata)
        vm.load()
        await fulfillment(of: [began], timeout: 1)
        try metadata.save(.init(credentials: ["after": record]))
        for _ in 0..<20 { vm.load() }
        XCTAssertTrue(vm.valueAvailability.isEmpty)
        gate.signal()
        try await finish(vm)
        XCTAssertEqual(io.reads, 2)
        XCTAssertNil(vm.valueAvailability["before"])
        XCTAssertEqual(vm.valueAvailability["after"]?.state, .missing)
    }
}
