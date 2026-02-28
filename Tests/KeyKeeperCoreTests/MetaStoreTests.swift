import XCTest
@testable import KeyKeeperCore

final class MetaStoreTests: XCTestCase {
    var tmpDir: URL!
    var store: MetaStore!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = MetaStore(directory: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testLoadCreatesDefaultWhenMissing() throws {
        let meta = try store.load()
        XCTAssertEqual(meta.version, 1)
        XCTAssertTrue(meta.credentials.isEmpty)
    }

    func testSaveAndLoad() throws {
        var meta = MetaFile()
        meta.credentials["test"] = Credential(
            label: "Test", notes: "n", links: [],
            fields: ["k": CredentialField(secret: true)],
            security: .standard, created: "2026-02-28", updated: "2026-02-28"
        )
        try store.save(meta)
        let loaded = try store.load()
        XCTAssertEqual(loaded.credentials.count, 1)
        XCTAssertEqual(loaded.credentials["test"]?.label, "Test")
    }
}
