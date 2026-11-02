import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

/// Actual App mutation entry points over file metadata and a fake Keychain. No GUI or real IO.
@MainActor
final class MutationIntegrityAdmissionTests: XCTestCase {
    private var directory: URL!
    private var integrity: FakeKeychainIO!
    private var values: FakeKeychainIO!
    private var store: MetaStore!
    private var service: KeychainCredentialService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-admission-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        integrity = FakeKeychainIO()
        values = FakeKeychainIO()
        store = MetaStore(directory: directory, integrityIO: integrity)
        service = KeychainCredentialService(store: KeychainBlobStore(io: values))
        try service.save(credentialId: "existing", fieldName: "token", value: "synthetic-original", security: .strict)
        try store.save(MetaFile(credentials: ["existing": fixtureCredential()]))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixtureCredential() -> Credential {
        .init(label: "Existing fixture", notes: "Keep this", links: [],
              fields: ["token": .init(secret: true)], security: .strict,
              created: "2026-11-02", updated: "2026-11-02")
    }

    func testAddRejectsUnavailableIntegrityBeforeWritingAnyValue() throws {
        let original = try Data(contentsOf: store.fileURL)
        let originalValues = values.blob
        let writes = values.writes
        let model = AddCredentialViewModel(session: service, store: store, approvals: .inMemory())
        model.label = "New fixture"
        model.credentialId = "new-fixture"
        model.fields = [.init(name: "token", value: "synthetic-candidate")]
        integrity.failReads = true

        XCTAssertFalse(model.save())

        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertNotNil(model.errorMessage)
    }

    func testDeleteRejectsUnavailableIntegrityBeforeDeletingValues() throws {
        let original = try Data(contentsOf: store.fileURL)
        let originalValues = values.blob
        let writes = values.writes
        let model = CredentialListViewModel(session: service, store: store)
        integrity.failReads = true

        XCTAssertFalse(model.delete(id: "existing"))

        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertNotNil(model.errorMessage)
    }

    func testEditRejectsUnavailableIntegrityBeforeRenamingOrReplacingValues() throws {
        let original = try Data(contentsOf: store.fileURL)
        let originalValues = values.blob
        let writes = values.writes
        let model = CredentialDetailViewModel(credentialId: "existing", credential: fixtureCredential(),
            session: service, store: store, approvals: .inMemory())
        model.fields[0].name = "renamed-token"
        model.fields[0].value = "synthetic-replacement"
        integrity.failReads = true

        XCTAssertFalse(model.saveChanges())

        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertNotNil(model.errorMessage)
    }

    func testReloadKeepsLastKnownRowsWhenIntegrityBecomesUnavailable() throws {
        let model = CredentialListViewModel(session: service, store: store)
        model.load()
        XCTAssertEqual(model.credentials.map(\.id), ["existing"])
        XCTAssertNil(model.loadFailure)
        integrity.failReads = true

        model.load()

        XCTAssertEqual(model.credentials.map(\.id), ["existing"])
        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.metadataTampered, "Unavailable verification must not offer to bless an unverified file")
    }

    func testDetailRevealAndCopyRefuseUnavailableIntegrityWithoutReadingValues() throws {
        let model = CredentialDetailViewModel(credentialId: "existing", credential: fixtureCredential(),
            session: service, store: store, approvals: .inMemory())
        let reads = values.ordinaryReads
        integrity.failReads = true

        model.toggleFieldVisibility(at: 0)
        XCTAssertNil(model.copyFieldValue("token"))
        XCTAssertThrowsError(try model.storedValue(for: model.fields[0]))

        XCTAssertEqual(values.ordinaryReads, reads)
        XCTAssertFalse(model.fields[0].visible)
        XCTAssertNotNil(model.errorMessage)
    }

    func testClipboardApprovalRechecksIntegrityBeforeReadingOrWritingCandidate() throws {
        let source = AdmissionClipboardSource()
        let controller = ClipboardSaveController(service: service, metaStore: store, approvals: .inMemory(),
            clipboard: source, present: { _, _ in }, update: { _ in }, dismiss: {}, reopen: {})
        defer { controller.cancel() }
        var response: ClipboardSaveResponse?
        controller.receive(.init(credentialId: "imported", fieldName: "token", create: true),
            callerName: "Fixture", isConnected: { true }) { response = $0 }
        XCTAssertTrue(controller.isPending)
        let original = try Data(contentsOf: store.fileURL)
        let originalValues = values.blob
        let writes = values.writes
        integrity.failReads = true

        controller.resolve(approved: true)

        XCTAssertEqual(response?.success, false)
        XCTAssertEqual(response?.errorCode, .storageUnavailable)
        XCTAssertEqual(source.reads, 0)
        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testEnvApprovalRechecksIntegrityBeforeWritingAnyValue() throws {
        let source = directory.appendingPathComponent(".env")
        try Data("API_KEY=synthetic-env-candidate".utf8).write(to: source)
        let controller = EnvImportController(service: service, metaStore: store, approvals: .inMemory(),
            present: { _, _ in }, dismiss: {})
        defer { controller.cancel() }
        var response: ClipboardSaveResponse?
        controller.receive(.init(credentialId: "imported", filePath: source.path),
            callerName: "Fixture", isConnected: { true }) { response = $0 }
        XCTAssertTrue(controller.isPending)
        let original = try Data(contentsOf: store.fileURL)
        let originalValues = values.blob
        let writes = values.writes
        integrity.failReads = true

        controller.resolve(approved: true)

        XCTAssertEqual(response?.success, false)
        XCTAssertEqual(response?.errorCode, .storageUnavailable)
        XCTAssertEqual(values.writes, writes)
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testLegacyUnsignedClipboardApprovalCanEstablishItsFirstSignature() throws {
        integrity.blob = nil
        try MetaStore(directory: directory).save(MetaFile(credentials: ["existing": fixtureCredential()]))
        let controller = ClipboardSaveController(service: service, metaStore: store, approvals: .inMemory(),
            clipboard: AdmissionClipboardSource(), present: { _, _ in }, update: { _ in }, dismiss: {}, reopen: {})
        defer { controller.cancel() }
        var response: ClipboardSaveResponse?
        controller.receive(.init(credentialId: "imported", fieldName: "token", create: true),
            callerName: "Fixture", isConnected: { true }) { response = $0 }
        XCTAssertTrue(controller.isPending)
        XCTAssertNil(integrity.blob, "Showing the request is read-only")

        controller.resolve(approved: true)

        XCTAssertEqual(response?.success, true, response?.detail ?? "")
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
        XCTAssertEqual(try service.retrieve(credentialId: "imported", fieldName: "token"), "synthetic-clipboard-candidate")
    }

    func testLegacyUnsignedEnvApprovalCanEstablishItsFirstSignature() throws {
        integrity.blob = nil
        try MetaStore(directory: directory).save(MetaFile(credentials: ["existing": fixtureCredential()]))
        let source = directory.appendingPathComponent(".env")
        try Data("API_KEY=synthetic-env-candidate".utf8).write(to: source)
        let controller = EnvImportController(service: service, metaStore: store, approvals: .inMemory(),
            present: { _, _ in }, dismiss: {})
        defer { controller.cancel() }
        var response: ClipboardSaveResponse?
        controller.receive(.init(credentialId: "imported", filePath: source.path),
            callerName: "Fixture", isConnected: { true }) { response = $0 }
        XCTAssertTrue(controller.isPending)
        XCTAssertNil(integrity.blob, "Showing the request is read-only")

        controller.resolve(approved: true)

        XCTAssertEqual(response?.success, true)
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
        XCTAssertEqual(try service.retrieve(credentialId: "imported", fieldName: "api-key"), "synthetic-env-candidate")
    }
}

@MainActor
private final class AdmissionClipboardSource: ClipboardSaveSource {
    let changeCount = 1
    var reads = 0
    func readText() -> String? { reads += 1; return "synthetic-clipboard-candidate" }
    func clearIfUnchanged(since count: Int) {}
}
