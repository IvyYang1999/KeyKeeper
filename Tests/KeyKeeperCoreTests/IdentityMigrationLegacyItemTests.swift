import XCTest
import Foundation
import Security
@testable import KeyKeeperCore

/// The copy from before 0.3.7 after a migration, and the XPC bridge's request encoding. KeyKeeper
/// never deletes the old copy: it only names the old Keychain items still there, so the person can
/// delete them in Keychain Access. No Keychain, no XPC here: lookups are faked.
final class IdentityMigrationLegacyItemTests: XCTestCase {
    private final class MemoryDestination: IdentityMigrationDestination {
        var items: [IdentityMigrationItem: Data] = [:], files: [String: Data] = [:], journal: Data?
        func readItem(_ item: IdentityMigrationItem) throws -> Data? { items[item] }
        func createItem(_ item: IdentityMigrationItem, data: Data) throws { items[item] = data }
        func readFile(_ name: String) throws -> Data? { files[name] }
        func createFile(_ name: String, data: Data) throws { files[name] = data }
        func readJournal() throws -> Data? { journal }
        func writeJournal(_ data: Data, replacingExisting: Bool) throws { journal = data }
    }

    /// Synthetic old data with no secret.
    private let legacy = IdentityMigrationSource(metadataHistory: Data("[]".utf8), preferences: Data("{}".utf8))

    /// The receipt's digest is of the source as copied, and survives the trip the source takes
    /// (service encodes, App decodes and re-encodes).
    func testReceiptDigestSurvivesTheBridgeEncoding() throws {
        let received = try IdentityMigrationSource.decode(try legacy.encoded())
        XCTAssertEqual(try received.digest(), try legacy.digest())
        var changed = legacy; changed.metadataHistory = Data("[{}]".utf8)
        XCTAssertNotEqual(try changed.digest(), try legacy.digest())
    }

    /// Settings reads what a completed migration copied: nothing before it completes.
    func testCompletedSummaryIsTheCopyOnceComplete() throws {
        let destination = MemoryDestination(), coordinator = IdentityMigrationCoordinator(destination: destination)
        XCTAssertNil(try coordinator.completedSummary(), "Nothing copied yet")
        let summary = try coordinator.migrate(source: legacy, expectedLegacyData: true)
        XCTAssertEqual(try coordinator.completedSummary(), summary)
    }

    /// Old item names are shown only after keys or website logins were actually copied: after a
    /// first install there is nothing the person should delete.
    func testOldItemsArePointedAtOnlyAfterSomethingWasCopied() {
        XCTAssertFalse(IdentityMigrationSummary(credentialCount: 0, missingValueCount: 0, browserSessionCount: 0).copiedLegacyData)
        XCTAssertTrue(IdentityMigrationSummary(credentialCount: 2, missingValueCount: 0, browserSessionCount: 0).copiedLegacyData)
        XCTAssertTrue(IdentityMigrationSummary(credentialCount: 0, missingValueCount: 1, browserSessionCount: 0).copiedLegacyData)
        XCTAssertTrue(IdentityMigrationSummary(credentialCount: 0, missingValueCount: 0, browserSessionCount: 1).copiedLegacyData)
    }

    /// The names the person is told to delete: every old item the capture reads, and no item of
    /// the new identity. A test fixture only ever names its own items.
    func testNamedItemsAreExactlyTheOldOnes() throws {
        XCTAssertEqual(IdentityMigrationLegacyCapture.itemServices(fixture: nil), [
            "com.keykeeper.credentials", "com.keykeeper.metadata-mac", "com.keykeeper.credentials.approvals",
            "com.keykeeper.browser-sessions", "com.keykeeper.credentials.browser-import-proposals",
            "com.keykeeper.credentials.local-sync-journal"])
        let id = UUID().uuidString
        let fixture = try XCTUnwrap(try IdentityMigrationFixture.resolve(environment: triple(id)))
        let service = "com.keykeeper.test.migration." + id
        XCTAssertEqual(IdentityMigrationLegacyCapture.itemServices(fixture: fixture), [
            service, service + ".metadata-mac", service + ".approvals", service + ".browser-sessions",
            service + ".browser-import-proposals", service + ".local-sync-journal"])
    }

    /// Only the names still there, in a fixed order.
    func testPresenceNamesWhatIsLeftInOrder() throws {
        let names = IdentityMigrationLegacyCapture.itemServices(fixture: nil)
        let left: Set = [names[4], names[0]]
        XCTAssertEqual(try LegacyItemPresence.remaining(services: names, present: { left.contains($0) }), [names[0], names[4]])
        XCTAssertEqual(try LegacyItemPresence.remaining(services: names, present: { _ in false }), [])
    }

    /// A failed check is an error, never "nothing left": callers then name every item.
    func testFailedCheckIsNotNothingLeft() {
        XCTAssertThrowsError(try LegacyItemPresence.remaining(present: { _ in throw IdentityMigrationError.unavailable }))
    }

    /// The check asks for attributes of one item, never its value, and never shows a dialog. It
    /// looks at the person's keychains, not the new protected storage.
    func testPresenceQueryNeverAsksForAValue() {
        let query = LegacyItemPresence.query("com.keykeeper.credentials")
        XCTAssertNil(query[kSecReturnData as String])
        XCTAssertNil(query[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "keykeeper")
        XCTAssertEqual(query[kSecAttrService as String] as? String, "com.keykeeper.credentials")
    }

    /// The service accepts the real sources (no fixture) or the complete isolated triple, nothing else.
    func testBridgeFixtureIsTheIsolatedTripleOrNothing() throws {
        XCTAssertNil(try IdentityMigrationBridge.decodeFixture(nil))
        let id = UUID().uuidString
        let fixture = try XCTUnwrap(try IdentityMigrationFixture.resolve(environment: triple(id)))
        let decoded = try XCTUnwrap(try IdentityMigrationBridge.decodeFixture(try IdentityMigrationBridge.encodeFixture(fixture)))
        XCTAssertEqual(decoded.environment, fixture.environment)
        var production = triple(id); production["KEYKEEPER_DATA_DIR"] = StorageIdentity.legacy.directory.path
        for bad in [try JSONEncoder().encode(production), Data("not json".utf8), Data("{}".utf8),
                    Data(repeating: 0x20, count: 5000)] {
            XCTAssertThrowsError(try IdentityMigrationBridge.decodeFixture(bad)) {
                XCTAssertEqual($0 as? IdentityMigrationError, .identity)
            }
        }
    }

    func testEveryErrorSurvivesTheReplyCode() {
        for error in [IdentityMigrationError.unavailable, .malformed, .unsignedMetadata, .activeImport,
                      .sourceChanged, .destinationConflict, .legacyRunning, .identity] {
            XCTAssertEqual(IdentityMigrationBridge.error(error.exitCode), error)
        }
        XCTAssertEqual(IdentityMigrationBridge.error(1), .unavailable)
    }

    private func triple(_ id: String) -> [String: String] {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("keykeeper-migration-" + id)
        return ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.migration." + id,
                "KEYKEEPER_DATA_DIR": directory.path,
                "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-migration-" + id + ".sock"]
    }
}
