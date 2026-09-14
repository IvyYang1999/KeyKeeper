import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import KeyKeeperTestSupport

@MainActor
final class AddCredentialSourcesTests: XCTestCase {
    private func makeVM() throws -> AddCredentialViewModel {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return AddCredentialViewModel(session: KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO())),
                                      store: MetaStore(directory: dir))
    }

    func test从剪贴板只差一个名字() throws {
        let vm = try makeVM()
        vm.prefillFromClipboard("sk-synthetic", changeCount: 42)
        XCTAssertEqual(vm.fields.first?.value, "sk-synthetic")
        XCTAssertEqual(vm.fields.first?.visible, false, "值仍然遮罩")
        XCTAssertEqual(vm.clipboardChangeCount, 42)
        XCTAssertFalse(vm.isValid)
        vm.label = "OpenAI"; vm.autoGenerateId()
        XCTAssertTrue(vm.isValid)
    }

    func test从文件用文件名建议名字且不需要填值() throws {
        let vm = try makeVM()
        vm.useFile(URL(fileURLWithPath: "/tmp/ga4-service.json"))
        XCTAssertEqual(vm.label, "ga4-service")
        XCTAssertEqual(vm.credentialId, "ga4-service")
        XCTAssertTrue(vm.isValid)
        XCTAssertTrue(vm.hasDraft)
    }

    func test重置会清掉来源() throws {
        let vm = try makeVM()
        vm.useFile(URL(fileURLWithPath: "/tmp/a.json"))
        vm.prefillFromClipboard("x", changeCount: 1)
        XCTAssertNil(vm.sourceFile)
        vm.reset()
        XCTAssertNil(vm.clipboardChangeCount)
    }
}

