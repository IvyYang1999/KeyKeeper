import Foundation
import XCTest
@testable import KeyKeeperCLI
@testable import KeyKeeperCore

private final class MemoryBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data) throws { blob = data }
}

final class MigrateStorageCommandTests: XCTestCase {
    private func makeMeta() -> MetaFile {
        MetaFile(credentials: [
            "openai": Credential(
                label: "OpenAI", notes: "", links: [],
                fields: [
                    "api-key": CredentialField(secret: true),
                    "org-id": CredentialField(value: "org-1", secret: false),
                ],
                security: .standard, created: "2026-01-01", updated: "2026-01-01"
            ),
            "stripe": Credential(
                label: "Stripe", notes: "", links: [],
                fields: ["token": CredentialField(secret: true)],
                security: .strict, created: "2026-01-01", updated: "2026-01-01"
            ),
        ])
    }

    func test只迁移secret字段并逐条校验() throws {
        let store = KeychainBlobStore(io: MemoryBlobIO())
        var fetched: [String] = []
        var logs: [String] = []
        let executor = MigrationExecutor(
            loadMeta: { self.makeMeta() },
            fetchValue: { id, field, all in
                fetched.append("\(id).\(field)")
                XCTAssertFalse(all.isEmpty)
                return "value-of-\(id).\(field)"
            },
            store: store,
            deleteLegacyItem: { _, _ in XCTFail("migrate must not delete legacy items") },
            log: { logs.append($0) }
        )

        try executor.migrate(dryRun: false)

        XCTAssertEqual(fetched.sorted(), ["openai.api-key", "stripe.token"])
        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "api-key"), "value-of-openai.api-key")
        XCTAssertEqual(try store.retrieve(credentialId: "stripe", fieldName: "token"), "value-of-stripe.token")
        XCTAssertTrue(logs.contains { $0.contains("2/2") })
        XCTAssertFalse(logs.joined().contains("value-of-"), "values must never be logged")
    }

    func test单条失败继续迁移其余并以非零退出() throws {
        let store = KeychainBlobStore(io: MemoryBlobIO())
        let executor = MigrationExecutor(
            loadMeta: { self.makeMeta() },
            fetchValue: { id, _, _ in
                if id == "stripe" { throw IPCError.noAuthorization("denied") }
                return "ok-value"
            },
            store: store,
            deleteLegacyItem: { _, _ in },
            log: { _ in }
        )

        XCTAssertThrowsError(try executor.migrate(dryRun: false))
        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "api-key"), "ok-value")
        XCTAssertThrowsError(try store.retrieve(credentialId: "stripe", fieldName: "token"))
    }

    func testDryRun不取值不写入() throws {
        let io = MemoryBlobIO()
        let executor = MigrationExecutor(
            loadMeta: { self.makeMeta() },
            fetchValue: { _, _, _ in XCTFail("dry run must not fetch"); return "" },
            store: KeychainBlobStore(io: io),
            deleteLegacyItem: { _, _ in XCTFail("dry run must not delete") },
            log: { _ in }
        )
        try executor.migrate(dryRun: true)
        XCTAssertNil(io.blob)
    }

    func testDeleteLegacy按secret字段逐条删除() throws {
        var deleted: [String] = []
        let executor = MigrationExecutor(
            loadMeta: { self.makeMeta() },
            fetchValue: { _, _, _ in XCTFail("delete-legacy must not fetch"); return "" },
            store: KeychainBlobStore(io: MemoryBlobIO()),
            deleteLegacyItem: { id, field in deleted.append("\(id).\(field)") },
            log: { _ in }
        )
        try executor.deleteLegacyItems()
        XCTAssertEqual(deleted.sorted(), ["openai.api-key", "stripe.token"])
    }
}
