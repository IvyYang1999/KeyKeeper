import XCTest
@testable import KeyKeeperApp
@testable import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class IPCLocalRecoveryTests: XCTestCase {
    private func fixture() throws -> (URL, MetaStore, IPCServer, FakeKeychainIO) {
        // Keep sockaddr_un comfortably below the platform's length limit.
        let directory = URL(fileURLWithPath: "/tmp/kk-recovery-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let meta = MetaStore(directory: directory)
        let importsIO = FakeKeychainIO()
        let imports = BrowserImportProposalStore(io: importsIO, marker: FileBrowserImportProposalMarker(directory: directory))
        let server = IPCServer(session: KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO())),
            metaStore: meta, approvals: .inMemory(), browserImportProposalStore: imports)
        return (directory, meta, server, importsIO)
    }

    func testOnlySocketOwnerRecoversBeforeImportRestoration() throws {
        let (directory, _, first, importsIO) = try fixture()
        let socket = directory.appendingPathComponent("ipc.sock").path
        var recoveries = 0
        importsIO.onRead = { XCTAssertEqual(recoveries, 1, "Recovery must finish before restoring imports") }
        guard case .started = first.start(socketPath: socket, recoverVault: { recoveries += 1 }) else {
            return XCTFail("First synthetic server must own socket")
        }
        defer { first.stop() }
        XCTAssertGreaterThan(importsIO.ordinaryReads + importsIO.reads, 0)
        let (_, _, duplicate, duplicateIO) = try fixture()
        guard case .anotherInstanceRunning = duplicate.start(socketPath: socket,
            recoverVault: { recoveries += 1 }) else { return XCTFail("Second server must not recover") }
        XCTAssertEqual(recoveries, 1)
        XCTAssertEqual(duplicateIO.ordinaryReads + duplicateIO.reads, 0)
    }

    func testRecoveryFailureKeepsAppAvailableButSkipsRestoration() throws {
        let (directory, _, server, importsIO) = try fixture()
        guard case .started = server.start(socketPath: directory.appendingPathComponent("ipc.sock").path,
            recoverVault: { throw LocalVaultCommitError.conflict }) else { return XCTFail("UI must still be available") }
        defer { server.stop() }
        XCTAssertTrue(server.vaultRecoveryFailed)
        XCTAssertEqual(importsIO.ordinaryReads + importsIO.reads, 0)
    }
}
