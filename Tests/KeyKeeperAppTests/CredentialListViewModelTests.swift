import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class CredentialListViewModelTests: XCTestCase {
    private var directory: URL!
    private var store: MetaStore!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-list-vm-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MetaStore(directory: directory)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 【曾经的 bug】meta.json 损坏时列表显示「No credentials stored」，像是数据丢了。
    func test曾经的Bug元数据损坏时区分读取失败与空列表() throws {
        try Data("{ not json".utf8).write(to: directory.appendingPathComponent("meta.json"))
        let vm = CredentialListViewModel(session: NoopSession(), store: store)

        vm.load()

        XCTAssertTrue(vm.credentials.isEmpty)
        let failure = try XCTUnwrap(vm.loadFailure)
        XCTAssertEqual(failure.fileURL, store.fileURL)
        XCTAssertFalse(failure.reason.isEmpty)
    }

    func test没有文件时是空列表而非失败() {
        let vm = CredentialListViewModel(session: NoopSession(), store: store)
        vm.load()
        XCTAssertTrue(vm.credentials.isEmpty)
        XCTAssertNil(vm.loadFailure)
    }

    func test修复文件后重新加载清除失败状态() throws {
        let metaURL = directory.appendingPathComponent("meta.json")
        try Data("{ not json".utf8).write(to: metaURL)
        let vm = CredentialListViewModel(session: NoopSession(), store: store)
        vm.load()
        XCTAssertNotNil(vm.loadFailure)

        try store.save(MetaFile(credentials: [:]))
        vm.load()
        XCTAssertNil(vm.loadFailure)
    }
}

private final class NoopSession: CredentialSessionManaging {
    func status() -> SessionStatus { .unlocked(expiresAt: nil) }
    func retrieve(credentialId: String, fieldName: String) throws -> String { "" }
    func save(credentialId: String, fieldName: String, value: String, security: SecurityLevel) throws {}
    func delete(credentialId: String, fieldName: String) throws {}
}
