import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

final class SaveMissingTests: XCTestCase {
    func testInsertPreservesEveryOtherValueAndRefusesOverwrite() throws {
        let io = FakeKeychainIO()
        let store = KeychainBlobStore(io: io)
        try store.save(credentialId: "existing", fieldName: "key", value: "synthetic-original")
        try store.saveMissing(credentialId: "recovery", fieldName: "key", value: "synthetic-restored")
        XCTAssertEqual(try store.retrieve(credentialId: "existing", fieldName: "key"), "synthetic-original")
        let before = io.blob
        XCTAssertThrowsError(try store.saveMissing(credentialId: "existing", fieldName: "key", value: "wrong"))
        XCTAssertEqual(io.blob, before)
    }

    func testMissingStoreAndUnknownVersionCannotBeRecreated() throws {
        let io = FakeKeychainIO()
        let meta = MetaFile(credentials: ["old": Credential(label: "Old", notes: "", links: [],
            fields: ["key": .init(secret: true)], security: .strict, created: "", updated: "")])
        let store = KeychainBlobStore(io: io, loadMetadata: { meta })
        XCTAssertThrowsError(try store.saveMissing(credentialId: "old", fieldName: "key", value: "synthetic"))
        XCTAssertNil(io.blob)
        io.blob = Data(#"{"version":99,"credentials":{}}"#.utf8)
        let before = io.blob
        XCTAssertThrowsError(try store.saveMissing(credentialId: "old", fieldName: "key", value: "synthetic"))
        XCTAssertEqual(io.blob, before)
    }
}
