import XCTest
import KeyKeeperCore
import KeyKeeperTestSupport
@testable import KeyKeeperApp

/// 【曾经的问题】2026-11-09 yyt：「它把我们自动生成的名称和用户自己填写的名称混在一起了」。
/// 名称下面挂着组 ID 和命令，密钥名格子里预先写好黑字 api-key，下面再一行 → API_KEY。
/// Now what the person types and what KeyKeeper derives are apart: the first key's name box
/// starts empty (api-key is only its grey placeholder and what an empty first name becomes),
/// and the ID, the command and the variables live together in one generated block.
@MainActor
final class AddFormGeneratedNamesTests: XCTestCase {
    private var directory: URL!
    private var store: MetaStore!
    private var session: KeychainCredentialService!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-add-generated-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MetaStore(directory: directory)
        session = KeychainCredentialService(store: KeychainBlobStore(io: FakeKeychainIO()))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func model() -> AddCredentialViewModel {
        AddCredentialViewModel(session: session, store: store, approvals: .inMemory())
    }

    func test曾经的问题密钥名格子不预先替人填好() {
        let vm = model()
        XCTAssertEqual(vm.fields.map(\.name), [""], "Nothing typed for the person")
        XCTAssertEqual(AddCredentialViewModel.namingFirst(vm.fields).map(\.name), [AddCredentialViewModel.defaultFieldName])
        XCTAssertFalse(vm.hasDraft)

        vm.prefillFromClipboard("sk-synthetic-clipboard", changeCount: 1)
        XCTAssertEqual(vm.fields.map(\.name), [""])
        vm.reset()
        XCTAssertEqual(vm.fields.map(\.name), [""])
        XCTAssertTrue(vm.selectProvider("openai"))
        XCTAssertTrue(vm.selectProvider(""))
        XCTAssertEqual(vm.fields.map(\.name), [""])
        vm.prefill(label: "Synthetic", fields: [], notes: nil)
        XCTAssertEqual(vm.fields.map(\.name), [""])
        vm.prefill(label: "Synthetic", fields: ["token"], notes: nil)
        XCTAssertEqual(vm.fields.map(\.name), ["token"], "A link that names its keys still names them")
    }

    func test没填名字的第一把key存成api_key后面的仍要名字() throws {
        let vm = model()
        vm.label = "Synthetic unnamed"
        vm.autoGenerateId()
        vm.fields[0].value = "sk-synthetic-unnamed"
        XCTAssertTrue(vm.isValid)
        XCTAssertTrue(vm.save(), vm.errorMessage ?? "")
        let saved = try XCTUnwrap(store.load().credentials[vm.credentialId])
        XCTAssertEqual(Array(saved.fields.keys), [AddCredentialViewModel.defaultFieldName])
        XCTAssertNil(saved.fields[AddCredentialViewModel.defaultFieldName]?.displayName)

        let second = model()
        second.label = "Synthetic second"
        second.autoGenerateId()
        second.fields = [FieldEntry(value: "sk-synthetic-a"), FieldEntry(value: "sk-synthetic-b")]
        XCTAssertFalse(second.save())
        XCTAssertNil(second.fieldErrors[second.fields[0].id])
        XCTAssertNotNil(second.fieldErrors[second.fields[1].id], "Only the first key has a name to fall back on")
    }

    func test曾经的问题自动生成的命令和变量集中在一处() {
        let vm = model()
        XCTAssertNil(vm.generatedCommand, "No name yet, nothing generated")
        XCTAssertEqual(vm.generatedVariables, ["API_KEY"])

        vm.label = "OpenAI"
        vm.autoGenerateId()
        XCTAssertEqual(vm.generatedCommand, "keykeeper run -c openai")

        vm.fields[0].name = "Deploy Token"
        vm.fields.append(FieldEntry(name: "base-url", isSecret: false))
        vm.fields.append(FieldEntry())
        XCTAssertEqual(vm.generatedVariables, ["DEPLOY_TOKEN", "BASE_URL"], "Unnamed later rows add nothing")

        XCTAssertTrue(vm.selectProvider("stripe", discardValues: true))
        let template = try? XCTUnwrap(vm.provider)
        XCTAssertEqual(vm.generatedVariables, template?.fields.flatMap(\.environmentNames))
        XCTAssertFalse(vm.generatedVariables.isEmpty)

        XCTAssertTrue(vm.selectProvider(""))
        vm.useFile(URL(fileURLWithPath: "/tmp/synthetic-service-account.json"))
        XCTAssertEqual(vm.generatedVariables, [], "A file's contents are not a variable")
    }
}
