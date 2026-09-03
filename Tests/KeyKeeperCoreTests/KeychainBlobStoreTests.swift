import Foundation
import XCTest
@testable import KeyKeeperCore

/// In-memory IO so these tests (and pre-commit) never touch the real keychain —
/// 经验.md 铁律：安全工具的测试绝不能碰真凭据源。
final class FakeBlobIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var readError: Error?
    var writeError: Error?
    private(set) var writeCount = 0

    func readBlob() throws -> Data? {
        if let readError { throw readError }
        return blob
    }

    func writeBlob(_ data: Data) throws {
        if let writeError { throw writeError }
        writeCount += 1
        blob = data
    }
}

final class KeychainBlobStoreTests: XCTestCase {
    func test保存后能取回且按字段隔离() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)

        try store.save(credentialId: "openai", fieldName: "api-key", value: "opaque-a")
        try store.save(credentialId: "openai", fieldName: "org-id", value: "opaque-b")
        try store.save(credentialId: "stripe", fieldName: "token", value: "opaque-c")

        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "api-key"), "opaque-a")
        XCTAssertEqual(try store.retrieve(credentialId: "openai", fieldName: "org-id"), "opaque-b")
        XCTAssertEqual(try store.retrieve(credentialId: "stripe", fieldName: "token"), "opaque-c")
        XCTAssertEqual(
            try store.fieldNamesByCredential(),
            ["openai": ["api-key", "org-id"], "stripe": ["token"]]
        )
    }

    func test缺失字段抛notFound() {
        let store = KeychainBlobStore(io: FakeBlobIO())
        XCTAssertThrowsError(try store.retrieve(credentialId: "nope", fieldName: "x")) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func test覆盖保存替换旧值() throws {
        let store = KeychainBlobStore(io: FakeBlobIO())
        try store.save(credentialId: "c", fieldName: "f", value: "old")
        try store.save(credentialId: "c", fieldName: "f", value: "new")
        XCTAssertEqual(try store.retrieve(credentialId: "c", fieldName: "f"), "new")
    }

    func test删除字段且删空凭据清理条目() throws {
        let io = FakeBlobIO()
        let store = KeychainBlobStore(io: io)
        try store.save(credentialId: "c", fieldName: "f1", value: "v1")
        try store.save(credentialId: "c", fieldName: "f2", value: "v2")

        try store.delete(credentialId: "c", fieldName: "f1")
        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f1"))
        XCTAssertEqual(try store.retrieve(credentialId: "c", fieldName: "f2"), "v2")

        try store.delete(credentialId: "c", fieldName: "f2")
        XCTAssertEqual(try store.fieldNamesByCredential(), [:])

        XCTAssertThrowsError(try store.delete(credentialId: "c", fieldName: "f2")) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func test损坏的blob拒绝服务而不是当成空库() throws {
        let io = FakeBlobIO()
        io.blob = Data("{ not json".utf8)
        let store = KeychainBlobStore(io: io)

        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f"))
        XCTAssertThrowsError(try store.save(credentialId: "c", fieldName: "f", value: "v"))
        XCTAssertEqual(io.writeCount, 0, "corrupt store must never be overwritten")
    }

    func testIO错误原样上抛() {
        let io = FakeBlobIO()
        io.readError = KeychainError.retrieveFailed(-25293)
        let store = KeychainBlobStore(io: io)
        XCTAssertThrowsError(try store.retrieve(credentialId: "c", fieldName: "f")) { error in
            guard case KeychainError.retrieveFailed = error else {
                return XCTFail("expected retrieveFailed, got \(error)")
            }
        }
    }

    func test并发读写不丢字段() throws {
        let store = KeychainBlobStore(io: FakeBlobIO())
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            try? store.save(credentialId: "cred\(index % 4)", fieldName: "field\(index)", value: "v\(index)")
        }
        let fields = try store.fieldNamesByCredential()
        XCTAssertEqual(fields.values.reduce(0) { $0 + $1.count }, 32)
    }
}

final class KeychainCredentialServiceTests: XCTestCase {
    func test永远是解锁态且CRUD直通() throws {
        let service = KeychainCredentialService(store: KeychainBlobStore(io: FakeBlobIO()))
        XCTAssertEqual(service.status(), .unlocked(expiresAt: nil))

        try service.save(credentialId: "c", fieldName: "f", value: "opaque", security: .strict)
        XCTAssertEqual(try service.retrieve(credentialId: "c", fieldName: "f"), "opaque")
        try service.delete(credentialId: "c", fieldName: "f")
        XCTAssertThrowsError(try service.retrieve(credentialId: "c", fieldName: "f"))
    }
}
