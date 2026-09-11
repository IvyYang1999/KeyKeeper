import XCTest
@testable import KeyKeeperCore

final class CreateCredentialTests: XCTestCase {
    private var old: MetaFile { .init(credentials: ["old": .init(label: "Old", notes: "", links: [],
        fields: ["missing": .init(secret: true)], security: .strict, created: "", updated: "")]) }

    func testCreateRefusesMissingCorruptUnknownVersionAndUnreadableStoresWithoutWrites() throws {
        let originals: [Data?] = [nil, Data("invalid".utf8), Data(#"{"version":99,"credentials":{}}"#.utf8)]
        for original in originals {
            let io = FakeBlobIO(); io.blob = original
            let store = KeychainBlobStore(io: io, loadMetadata: { self.old })
            XCTAssertThrowsError(try store.createCredential(credentialId: "new", values: ["a": "synthetic"]))
            XCTAssertEqual(io.blob, original); XCTAssertEqual(io.writeCount, 0)
        }
        let io = FakeBlobIO(); io.readError = KeychainError.retrieveFailed(-25293)
        XCTAssertThrowsError(try KeychainBlobStore(io: io).createCredential(credentialId: "new", values: ["a": "synthetic"]))
        XCTAssertEqual(io.writeCount, 0)
    }

    func testCreateRefusesMetadataIDsAndOrphanIDsEvenWithDifferentFields() throws {
        let io = FakeBlobIO()
        io.blob = Data(#"{"version":1,"credentials":{"orphan":{"kept":"synthetic"}}}"#.utf8)
        let original = io.blob
        let store = KeychainBlobStore(io: io, loadMetadata: { self.old })
        for id in ["old", "orphan"] {
            XCTAssertThrowsError(try store.createCredential(credentialId: id, values: ["different": "synthetic-new"]))
        }
        XCTAssertEqual(io.blob, original); XCTAssertEqual(io.writeCount, 0)
    }

    func testCreateIsOneWriteAndRetryNeverReplacesFirstResult() throws {
        let io = FakeBlobIO(); let store = KeychainBlobStore(io: io)
        try store.createCredential(credentialId: "new", values: ["a": "synthetic-a", "b": "synthetic-b"])
        let original = io.blob
        XCTAssertEqual(io.writeCount, 1)
        XCTAssertThrowsError(try store.createCredential(credentialId: "new", values: ["c": "different"]))
        XCTAssertEqual(io.blob, original); XCTAssertEqual(io.writeCount, 1)
    }

    func testCreateFailureAndWriteTimeDisappearanceNeverPartiallyWriteOrRecreate() throws {
        let io = FakeBlobIO(); let store = KeychainBlobStore(io: io)
        try store.createCredential(credentialId: "old", values: ["a": "synthetic"])
        let original = io.blob
        io.writeError = KeychainError.saveFailed(-25293)
        XCTAssertThrowsError(try store.createCredential(credentialId: "new", values: ["a": "a", "b": "b"]))
        XCTAssertEqual(io.blob, original)
        io.writeError = nil; io.beforeWrite = { io.blob = nil }
        XCTAssertThrowsError(try store.createCredential(credentialId: "new", values: ["a": "a"]))
        XCTAssertNil(io.blob); XCTAssertEqual(io.writeCount, 1)
    }

    func testConcurrentSameIDCreationHasExactlyOneWinner() throws {
        let io = FakeBlobIO(); let store = KeychainBlobStore(io: io)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            try? store.createCredential(credentialId: "same", values: ["field-\(index)": "synthetic"])
        }
        XCTAssertEqual(io.writeCount, 1)
        XCTAssertEqual(try store.fieldNamesByCredential()["same"]?.count, 1)
    }

    func testCreateRequiresReadableSupportedMetadataAndNonemptyInput() throws {
        let io = FakeBlobIO(); io.blob = Data(#"{"version":1,"credentials":{}}"#.utf8)
        let loaders: [() throws -> MetaFile] = [{ throw CocoaError(.fileReadNoPermission) }, { MetaFile(version: 99) }]
        for meta in loaders {
            XCTAssertThrowsError(try KeychainBlobStore(io: io, loadMetadata: meta)
                .createCredential(credentialId: "new", values: ["a": "synthetic"]))
        }
        let store = KeychainBlobStore(io: io)
        for values in [[:], ["": "synthetic"], ["a": ""]] {
            XCTAssertThrowsError(try store.createCredential(credentialId: "new", values: values))
        }
        XCTAssertEqual(io.writeCount, 0)
    }
}
