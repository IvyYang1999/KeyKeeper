import Foundation
import XCTest
@testable import KeyKeeperApp
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// Production App entry points and actual stores over temporary metadata/fake Keychain IO.
@MainActor
final class VaultMutationGateTests: XCTestCase {
    private enum Fault: Error { case interrupted }
    private var directory: URL!
    private var gate: VaultAccessGate!
    private var values: FakeKeychainIO!
    private var store: MetaStore!
    private var service: KeychainCredentialService!
    private var approvals: ApprovalStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("app-vault-gate-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        gate = VaultAccessGate()
        values = FakeKeychainIO()
        store = MetaStore(directory: directory, integrityIO: FakeKeychainIO(), accessGate: gate)
        service = KeychainCredentialService(store: KeychainBlobStore(io: values, accessGate: gate))
        approvals = ApprovalStore(io: FakeKeychainIO(), accessGate: gate)
        try service.save(credentialId: "existing", fieldName: "token", value: "synthetic-before", security: .strict)
        try store.save(MetaFile(credentials: ["existing": fixture()]))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    private func fixture() -> Credential {
        .init(label: "Fixture", notes: "", links: [], fields: ["token": .init(secret: true)],
              security: .strict, created: "2026-11-02", updated: "2026-11-02")
    }

    func testRecoveryRequiredBlocksAddEditDeleteAndRevealWithoutChangingBytes() throws {
        let add = AddCredentialViewModel(session: service, store: store, approvals: approvals)
        add.label = "Candidate"; add.credentialId = "candidate"
        add.fields = [.init(name: "token", value: "synthetic-new")]
        let detail = CredentialDetailViewModel(credentialId: "existing", credential: fixture(),
                                              session: service, store: store, approvals: approvals)
        detail.fields[0].value = "synthetic-replacement"
        let list = CredentialListViewModel(session: service, store: store)
        let original = try Data(contentsOf: store.fileURL), originalValues = values.blob
        let writes = values.writes
        XCTAssertThrowsError(try gate.withCommit { throw Fault.interrupted })
        XCTAssertFalse(add.save())
        XCTAssertFalse(detail.saveChanges())
        XCTAssertFalse(list.delete(id: "existing"))
        XCTAssertNil(detail.copyFieldValue("token"))
        detail.setProvider("openai")
        detail.setInjectOnly(false)
        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testPendingClipboardAndEnvCannotWriteAfterEvenSecretOnlyCommit() throws {
        let source = GateClipboardSource()
        let clipboard = ClipboardSaveController(service: service, metaStore: store, approvals: approvals,
            clipboard: source, present: { _, _ in }, update: { _ in }, dismiss: {}, reopen: {})
        let envURL = directory.appendingPathComponent("synthetic.env")
        try Data("API_KEY=synthetic-env".utf8).write(to: envURL)
        let env = EnvImportController(service: service, metaStore: store, approvals: approvals,
            present: { _, _ in }, dismiss: {})
        defer { clipboard.cancel(); env.cancel() }
        var clipboardResponse: ClipboardSaveResponse?, envResponse: ClipboardSaveResponse?
        clipboard.receive(.init(credentialId: "clip", fieldName: "token", create: true),
            callerName: "Fixture", isConnected: { true }) { clipboardResponse = $0 }
        env.receive(.init(credentialId: "env", filePath: envURL.path), callerName: "Fixture",
                    isConnected: { true }) { envResponse = $0 }
        XCTAssertTrue(clipboard.isPending); XCTAssertTrue(env.isPending)
        let metadata = try Data(contentsOf: store.fileURL)
        let rawAdapter = KeychainBlobStore(io: values)
        try gate.withCommit { try rawAdapter.save(credentialId: "existing", fieldName: "token", value: "synthetic-after") }
        let writes = values.writes
        XCTAssertEqual(try Data(contentsOf: store.fileURL), metadata, "This exercises unchanged metadata")
        clipboard.resolve(approved: true)
        env.resolve(approved: true)
        XCTAssertEqual(clipboardResponse?.success, false)
        XCTAssertEqual(envResponse?.success, false)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(try service.retrieve(credentialId: "existing", fieldName: "token"), "synthetic-after")
    }

    func testAddHoldsGateBetweenValueWriteAndMetadataPublication() throws {
        let transactionEntered = DispatchSemaphore(value: 0)
        let transactionFinished = expectation(description: "transaction observed complete add")
        let gate = self.gate!, store = self.store!
        let observed = ObservedGateSession(base: service) {
            // Underlying BlobStore has already returned and released its own lock. Only the
            // App's outer lease can exclude a transaction at this exact storage seam.
            DispatchQueue.global().async {
                defer { transactionFinished.fulfill() }
                do {
                    try gate.withCommit {
                        transactionEntered.signal()
                        XCTAssertNotNil(try store.load().credentials["candidate"])
                    }
                } catch { XCTFail("Synthetic transaction failed: \(error)") }
            }
            XCTAssertEqual(transactionEntered.wait(timeout: .now() + 0.05), .timedOut)
        }
        let add = AddCredentialViewModel(session: observed, store: store, approvals: approvals)
        add.label = "Candidate"; add.credentialId = "candidate"
        add.fields = [.init(name: "token", value: "synthetic-new")]
        XCTAssertNil(try store.load().credentials["candidate"])
        XCTAssertTrue(add.save())
        wait(for: [transactionFinished], timeout: 3)
        XCTAssertNotNil(try store.loadForUse().credentials["candidate"])
    }
}

@MainActor private final class GateClipboardSource: ClipboardSaveSource {
    let changeCount = 1
    var reads = 0
    func readText() -> String? { reads += 1; return "synthetic-clipboard" }
    func clearIfUnchanged(since count: Int) {}
}

private final class ObservedGateSession: CredentialSessionManaging {
    let base: KeychainCredentialService
    let afterMutation: () -> Void
    init(base: KeychainCredentialService, afterMutation: @escaping () -> Void) {
        self.base = base; self.afterMutation = afterMutation
    }
    func status() -> SessionStatus { base.status() }
    func retrieve(credentialId: String, fieldName: String) throws -> String {
        try base.retrieve(credentialId: credentialId, fieldName: fieldName)
    }
    func save(credentialId: String, fieldName: String, value: String, security: SecurityLevel) throws {
        try base.save(credentialId: credentialId, fieldName: fieldName, value: value, security: security)
        afterMutation()
    }
    func delete(credentialId: String, fieldName: String) throws {
        try base.delete(credentialId: credentialId, fieldName: fieldName); afterMutation()
    }
    func createCredential(credentialId: String, values: [String: String], security: SecurityLevel) throws {
        try base.createCredential(credentialId: credentialId, values: values, security: security); afterMutation()
    }
    func storedFieldNames(credentialId: String) throws -> Set<String> { try base.storedFieldNames(credentialId: credentialId) }
}
