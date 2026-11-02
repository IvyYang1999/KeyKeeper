import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class MetaStoreAdmissionTests: XCTestCase {
    private var directory: URL!
    private var io: FakeKeychainIO!
    private var store: MetaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("meta-admission-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        io = FakeKeychainIO()
        store = MetaStore(directory: directory, integrityIO: io)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDeniedIntegrityReadCannotBecomeUnsignedOrWriteMetadata() throws {
        try store.save(MetaFile())
        let original = try Data(contentsOf: store.fileURL)
        let key = io.blob
        let writes = io.writeCount
        io.failReads = true
        XCTAssertThrowsError(try store.loadVerified())
        XCTAssertThrowsError(try store.save(MetaFile()))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(io.blob, key)
        XCTAssertEqual(io.writeCount, writes)
    }

    func testSignedMetadataWithMissingKeyCannotCreateReplacement() throws {
        try store.save(MetaFile())
        let original = try Data(contentsOf: store.fileURL)
        io.blob = nil
        let writes = io.writeCount
        XCTAssertThrowsError(try store.loadVerified())
        XCTAssertThrowsError(try store.save(MetaFile()))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, writes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testMalformedIntegrityKeyCannotBeTreatedAsMissing() throws {
        io.blob = Data(repeating: 9, count: 31)
        XCTAssertThrowsError(try MetaIntegrityKey.existing(io: io))
        XCTAssertThrowsError(try store.loadVerified())
        XCTAssertThrowsError(try store.save(MetaFile()))
        XCTAssertEqual(io.blob, Data(repeating: 9, count: 31))
        XCTAssertEqual(io.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    private func unsignedMetadata() -> MetaFile {
        MetaFile(credentials: ["fixture": Credential(
            label: "Fixture", notes: "synthetic note", links: [],
            fields: ["token": .init(secret: true)], security: .strict,
            created: "2026-11-02", updated: "2026-11-02")])
    }

    private func writeRaw(_ metadata: MetaFile) throws {
        try JSONEncoder().encode(metadata).write(to: store.fileURL)
    }

    func testReadAdmissionIsNonInteractiveAndCannotBootstrap() throws {
        try writeRaw(unsignedMetadata())
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertEqual(try store.loadVerified().verdict, .unsigned)
        XCTAssertEqual(try store.loadForUse().credentials.count, 1)
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 0)
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertGreaterThan(io.reads, 0)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testFreshEmptyReadDoesNotCreateAnything() throws {
        XCTAssertTrue(try store.loadForUse().credentials.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 0)
    }

    func testRawCLIMetadataReadDoesNotAccessIntegrityKey() throws {
        try writeRaw(unsignedMetadata())
        io.failReads = true
        XCTAssertEqual(try store.load().credentials.count, 1)
        XCTAssertEqual(io.reads, 0)
        XCTAssertEqual(io.ordinaryReads, 0)
        XCTAssertThrowsError(try store.loadForUse())
    }

    func testLegacyPreparationEstablishesSignatureBeforeReturningAndIsIdempotent() throws {
        try writeRaw(unsignedMetadata())
        let prepared = try store.prepareForMutation()
        XCTAssertEqual(prepared.credentials.count, 1)
        XCTAssertNotNil(prepared.integrity)
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
        XCTAssertEqual(io.writeCount, 1)
        let signed = try Data(contentsOf: store.fileURL)
        _ = try store.prepareForMutation()
        XCTAssertEqual(io.writeCount, 1)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), signed)
        XCTAssertEqual(io.ordinaryReads, 0)
    }

    func testLegacyPreparationCannotProceedWhenKeyCreationFails() throws {
        try writeRaw(unsignedMetadata())
        let original = try Data(contentsOf: store.fileURL)
        io.failWrites = true
        XCTAssertThrowsError(try store.prepareForMutation())
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, 0)
    }

    func testTamperingCannotBeBlessedBySaveOrPreparationButOwnerReviewCanRepairIt() throws {
        try store.save(unsignedMetadata())
        var altered = try store.load()
        altered.credentials["fixture"]?.notes = "changed outside the app"
        try writeRaw(altered)
        let original = try Data(contentsOf: store.fileURL)
        let originalKey = io.blob
        let writes = io.writeCount
        XCTAssertEqual(try store.loadVerified().verdict, .tampered)
        XCTAssertThrowsError(try store.loadForUse())
        XCTAssertThrowsError(try store.prepareForMutation())
        XCTAssertThrowsError(try store.save(altered))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
        XCTAssertEqual(io.writeCount, writes)
        try store.trustCurrentMetadata()
        XCTAssertEqual(try store.loadVerified().verdict, .intact)
        XCTAssertEqual(try store.loadForUse().credentials["fixture"]?.notes, "changed outside the app")
        XCTAssertEqual(io.blob, originalKey)
        XCTAssertEqual(io.writeCount, writes)
    }

    func testEmptyMACWithExistingKeyIsTamperedNotUnsigned() throws {
        try store.save(unsignedMetadata())
        var altered = try store.load()
        altered.integrity = ""
        try writeRaw(altered)
        XCTAssertEqual(try store.loadVerified().verdict, .tampered)
        XCTAssertThrowsError(try store.loadForUse())
        XCTAssertThrowsError(try store.prepareForMutation())
    }

    func testOwnerReviewCannotBypassUnavailableIntegrityKey() throws {
        try store.save(unsignedMetadata())
        let original = try Data(contentsOf: store.fileURL)
        let writes = io.writeCount
        io.failReads = true
        XCTAssertThrowsError(try store.trustCurrentMetadata())
        io.failReads = false
        io.blob = nil
        XCTAssertThrowsError(try store.trustCurrentMetadata())
        XCTAssertNil(io.blob)
        XCTAssertEqual(io.writeCount, writes)
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testMetadataEditorAdmissionPrecedesValueCopiesAndGrantChanges() throws {
        let values = FakeKeychainIO()
        let blob = KeychainBlobStore(io: values, loadMetadata: { try self.store.load() })
        let service = KeychainCredentialService(store: blob)
        try service.save(credentialId: "fixture", fieldName: "token", value: "synthetic", security: .strict)
        try store.save(unsignedMetadata())
        let approvals = ApprovalStore.inMemory()
        try approvals.add(Approval(subject: .init(fingerprint: "synthetic-app", displayName: "Synthetic"),
                                   target: .credential(id: "fixture", fields: nil), duration: .always))
        let originalValues = values.blob
        let originalApprovals = try approvals.all()
        let writes = values.writeCount
        io.failReads = true
        let editor = MetadataEditor(session: service, metaStore: store, approvals: approvals)
        XCTAssertThrowsError(try editor.apply(.init(newGroupId: "renamed"), groupId: "fixture"))
        XCTAssertEqual(values.blob, originalValues)
        XCTAssertEqual(values.writeCount, writes)
        XCTAssertEqual(try approvals.all(), originalApprovals)
    }
}
