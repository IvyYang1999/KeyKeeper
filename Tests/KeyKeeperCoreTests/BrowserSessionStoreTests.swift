import XCTest
@testable import KeyKeeperCore

final class BrowserSessionStoreTests: XCTestCase {
    private func fixture() -> BrowserSessionImport {
        .init(id: UUID().uuidString, origin: "https://example.com", label: "Synthetic profile", cookies: [
            .init(name: "fixture", value: "synthetic", domain: "example.com", hostOnly: true,
                  path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)
        ])
    }
    func testSaveListAndSameIDReplayAreIdempotentAndConflictPreservesOriginal() throws {
        let io = FakeBlobIO(); let marker = MemoryBrowserMarker()
        let store = BrowserSessionStore(io: io, marker: marker)
        let input = fixture(); let first = try store.save(input)
        XCTAssertTrue(marker.exists)
        XCTAssertEqual(try store.save(input), first); XCTAssertEqual(io.writeCount, 1)
        var other = input; other.cookies[0].value = "different"
        let before = io.blob
        XCTAssertThrowsError(try store.save(other))
        XCTAssertEqual(io.blob, before)
        XCTAssertEqual(try store.list(), [first])
        try store.withSnapshot(id: input.id) { XCTAssertEqual($0, input) }
    }
    func testRestartWithMissingOrCorruptStoreFailsClosedAndDeleteDoesNotRecreate() throws {
        let io = FakeBlobIO(); let marker = MemoryBrowserMarker()
        let store = BrowserSessionStore(io: io, marker: marker)
        let input = fixture(); _ = try store.save(input)
        io.blob = nil
        let reopened = BrowserSessionStore(io: io, marker: marker)
        XCTAssertThrowsError(try reopened.save(fixture()))
        XCTAssertNil(io.blob)
        io.blob = Data("broken".utf8)
        XCTAssertThrowsError(try reopened.list())
        XCTAssertThrowsError(try reopened.delete(id: input.id))
        XCTAssertEqual(io.blob, Data("broken".utf8))
    }
    func testMarkerFailurePreventsFirstWriteAndLastDeleteRetainsEmptyStore() throws {
        let io = FakeBlobIO(); let marker = MemoryBrowserMarker(); marker.fail = true
        let store = BrowserSessionStore(io: io, marker: marker)
        let input = fixture()
        XCTAssertThrowsError(try store.save(input)); XCTAssertNil(io.blob)
        marker.fail = false
        _ = try store.save(input); try store.delete(id: input.id)
        XCTAssertNotNil(io.blob); XCTAssertTrue(try store.list().isEmpty)
        XCTAssertThrowsError(try store.withSnapshot(id: input.id) { _ in })
        _ = try store.save(fixture())
    }
    func testExpiredSnapshotCanBeListedAndDeletedButNotOpened() throws {
        let io = FakeBlobIO(); let marker = MemoryBrowserMarker()
        let store = BrowserSessionStore(io: io, marker: marker)
        var input = fixture(); input.cookies[0].expirationDate = 200
        _ = try store.save(input, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertThrowsError(try store.withSnapshot(id: input.id, now: Date(timeIntervalSince1970: 300)) { _ in })
        try store.delete(id: input.id)
    }
    func testProductionAndTestServiceNamespacesCannotTouchAPIKeyStore() throws {
        XCTAssertEqual(try BrowserSessionStore.serviceName(environment: [:]), "com.keykeeper.browser-sessions")
        XCTAssertThrowsError(try BrowserSessionStore.serviceName(environment: ["KEYKEEPER_DATA_DIR": "/tmp/fixture"]))
        let isolated = try BrowserSessionStore.serviceName(environment: ["KEYKEEPER_DATA_DIR": "/tmp/fixture",
            "KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.fixture",
            "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-fixture.sock"])
        XCTAssertEqual(isolated, "com.keykeeper.test.fixture.browser-sessions")
        XCTAssertNotEqual(isolated, "com.keykeeper.test.fixture")
    }
}

private final class MemoryBrowserMarker: BrowserSessionMarker {
    var exists = false; var fail = false
    func wasCreated() throws -> Bool { exists }
    func markCreated() throws { if fail { throw BrowserSessionError.unavailable }; exists = true }
}
