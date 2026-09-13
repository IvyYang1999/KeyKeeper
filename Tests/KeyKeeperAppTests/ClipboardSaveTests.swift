import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

private final class SaveTestIO: KeychainBlobIO, @unchecked Sendable {
    var blob: Data?
    var writes = 0
    var failWrites = false
    var afterWrite: (() throws -> Void)?
    func readBlob() throws -> Data? { blob }
    func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        if failWrites { throw CocoaError(.fileWriteNoPermission) }
        writes += 1; blob = data
        try afterWrite?()
    }
}
@MainActor private final class SaveTestClipboard: ClipboardSaveSource {
    var changeCount = 1
    var text: String? = "synthetic-import"
    var reads = 0
    var clears = 0
    func readText() -> String? { reads += 1; return text }
    func clearIfUnchanged(since count: Int) {
        if count == changeCount { text = nil; changeCount += 1; clears += 1 }
    }
}

@MainActor final class ClipboardSaveTests: XCTestCase {
    private var directory: URL!
    private var meta: MetaStore!
    private var io: SaveTestIO!
    private var service: KeychainCredentialService!
    private var clipboard: SaveTestClipboard!
    private var controller: ClipboardSaveController!
    private var results: [ClipboardSaveResponse] = []
    private var clock = Date()
    private var connected = true

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-save-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        meta = MetaStore(directory: directory)
        io = SaveTestIO()
        service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.meta.load() }))
        clipboard = SaveTestClipboard()
        controller = ClipboardSaveController(service: service, metaStore: meta, clipboard: clipboard,
            now: { self.clock }, present: { _, _ in }, dismiss: {})
        results = []; connected = true
    }
    override func tearDownWithError() throws {
        controller.cancel()
        controller = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func request(create: Bool = true, expect: String? = nil) {
        controller.receive(.init(credentialId: "fixture", fieldName: "key", create: create, expect: expect),
            callerName: "Test caller",
            isConnected: { self.connected }, completion: { self.results.append($0) })
    }
    private func credential() -> Credential {
        .init(label: "Existing", notes: "keep", links: [], fields: ["key": .init(secret: true)],
            security: .standard, created: "2026-01-01", updated: "2026-01-01")
    }
    func testCreateReadsOnlyAfterApprovalAndReturnsNoValue() throws {
        request()
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(clipboard.reads, 0)
        controller.resolve(approved: true)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.shape, ValueShape.of("synthetic-import"),
                       "回报形状（长度、是否 Base64），但绝不回报值")
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-import")
        XCTAssertEqual(try meta.load().credentials["fixture"]?.security, .strict)
        XCTAssertEqual(clipboard.clears, 1)
        controller.resolve(approved: true)
        XCTAssertEqual(io.writes, 1)
    }

    func testSourceImportApprovesTextOnlyAndNeverOverwrites() throws {
        let file = directory.appendingPathComponent("fixture.py")
        let bytes = Data("raise RuntimeError('never execute')\nADMIN_KEY = os.getenv('ADMIN_KEY', 'synthetic-value')".utf8)
        try bytes.write(to: file)
        let source = try CredentialFileSource(filePath: file.path, pythonSymbol: "ADMIN_KEY")
        var shown: ClipboardSaveController.Presentation?
        controller = ClipboardSaveController(service: service, metaStore: meta, present: { info, _ in shown = info }, dismiss: {})
        let request = ClipboardSaveRequest(credentialId: "fixture", fieldName: "key", create: true)
        controller.receive(request, callerName: "Test", isConnected: { true }, source: source,
                           completion: { self.results.append($0) })
        XCTAssertEqual(shown?.pythonSymbol, "ADMIN_KEY")
        XCTAssertEqual(shown?.fromBrowser, false)
        XCTAssertEqual(io.writes, 0)
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-value")
        XCTAssertNil(try meta.load().credentials["fixture"]?.fields["key"]?.fileFormat)
        XCTAssertEqual(try meta.load().credentials["fixture"]?.security, .strict)
        XCTAssertTrue(try GrantStore(directory: directory).grants(for: "fixture").isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        for create in [true, false] {
            controller.receive(.init(credentialId: "fixture", fieldName: "key", create: create), callerName: "Test",
                isConnected: { true }, source: source, completion: { self.results.append($0) })
            XCTAssertEqual(results.last?.errorCode, .valueExists)
        }
        XCTAssertEqual(io.writes, 1)
    }

    func testSourceCancellationAndFileMutationDoNotWrite() throws {
        let file = directory.appendingPathComponent("fixture.py")
        try Data("invalid Python !!!".utf8).write(to: file)
        for approved in [false, true] {
            let source = try CredentialFileSource(filePath: file.path, pythonSymbol: "ADMIN_KEY")
            controller.receive(.init(credentialId: "fixture", fieldName: "key", create: true), callerName: "Test",
                isConnected: { true }, source: source, completion: { self.results.append($0) })
            if approved { try Data("ADMIN_KEY='synthetic'".utf8).write(to: file, options: .atomic) }
            controller.resolve(approved: approved)
            XCTAssertEqual(results.last?.errorCode, approved ? .fileChanged : .denied)
            XCTAssertEqual(io.writes, 0)
        }
    }

    func testFileImportIsTypedNoOverwriteAndRetainsOriginal() throws {
        let file = directory.appendingPathComponent("fixture.json")
        let value = "{\"type\":\"service_account\",\"client_email\":\"fixture@example.invalid\",\"private_key\":\"synthetic-only\"}\n"
        try Data(value.utf8).write(to: file)
        let source = try CredentialFileSource(filePath: file.path)
        let request = ClipboardSaveRequest(credentialId: "fixture", fieldName: "key", create: true)
        controller.receive(request, callerName: "Test", isConnected: { true }, source: source,
                           completion: { self.results.append($0) })
        XCTAssertEqual(io.writes, 0)
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(try meta.load().credentials["fixture"]?.fields["key"]?.fileFormat, .serviceAccountJSON)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), value)
        XCTAssertEqual(try String(contentsOf: file), value)
        controller.receive(request, callerName: "Test", isConnected: { true }, source: source,
                           completion: { self.results.append($0) })
        XCTAssertEqual(results.last?.errorCode, .valueExists)
        XCTAssertEqual(io.writes, 1)
    }

    func testClipboardCannotRestoreFileFieldAsPlainText() throws {
        var fixture = credential()
        fixture.fields["key"] = .init(secret: true, fileFormat: .serviceAccountJSON)
        try service.save(credentialId: "other", fieldName: "key", value: "synthetic", security: .standard)
        try meta.save(.init(credentials: ["fixture": fixture]))
        request(create: false)
        XCTAssertEqual(results.last?.errorCode, .wrongFieldType)
        XCTAssertEqual(clipboard.reads, 0)
    }

    func testBrowserSourceReservesTargetWithoutShowingOrReadingUntilPaste() throws {
        var presentations = 0
        controller = ClipboardSaveController(service: service, metaStore: meta, clipboard: clipboard,
            now: { self.clock }, present: { info, _ in
                XCTAssertTrue(info.fromBrowser); presentations += 1
            }, dismiss: {})
        let browserSource = SaveTestClipboard()
        browserSource.text = "synthetic-browser"
        controller.receive(.init(credentialId: "fixture", fieldName: "key", create: true), callerName: "Test",
            isConnected: { self.connected }, source: browserSource, deferPresentation: true,
            completion: { self.results.append($0) })
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(presentations, 0)
        controller.resolve(approved: true)
        XCTAssertEqual(io.writes, 0)
        controller.presentPending()
        controller.presentPending()
        XCTAssertEqual(presentations, 1)
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(browserSource.clears, 1)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-browser")
    }
    func testCancelAndTimeoutNeverReadClipboardOrWrite() {
        request(); controller.resolve(approved: false)
        XCTAssertEqual(results.last?.errorCode, .denied)
        request(); clock.addTimeInterval(91); controller.expireIfNeeded()
        XCTAssertEqual(results.last?.errorCode, .expired)
        XCTAssertEqual(clipboard.reads, 0); XCTAssertEqual(io.writes, 0)
    }
    func testClipboardChangeAndDisconnectFailClosed() {
        request(); clipboard.changeCount += 1; controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .clipboardChanged)
        request(); connected = false; controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .disconnected)
        XCTAssertEqual(clipboard.reads, 0); XCTAssertEqual(io.writes, 0)
    }
    func testBusyRequestCannotConsumeOrReplaceFirstRequest() {
        request(); request()
        XCTAssertEqual(results.last?.errorCode, .busy)
        XCTAssertEqual(clipboard.reads, 0)
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true); XCTAssertEqual(io.writes, 1)
    }
    func testRestorePartialStorePreservesMetadataAndOtherValues() throws {
        try service.save(credentialId: "other", fieldName: "key", value: "synthetic-original", security: .standard)
        let original = MetaFile(credentials: ["fixture": credential(), "still-missing": credential()])
        try meta.save(original)
        let before = try Data(contentsOf: meta.fileURL)
        request(create: false); controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(try Data(contentsOf: meta.fileURL), before)
        XCTAssertEqual(try service.retrieve(credentialId: "other", fieldName: "key"), "synthetic-original")
        XCTAssertThrowsError(try service.validateStorage())
    }
    func testMetadataChangeAfterPromptPreventsSave() throws {
        request()
        try meta.save(.init(credentials: ["fixture": credential()]))
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .metadataChanged)
        XCTAssertEqual(clipboard.reads, 0); XCTAssertEqual(io.writes, 0)
    }
    func testExistingValueAndMissingStoreRejectedBeforeClipboardRead() throws {
        try service.save(credentialId: "fixture", fieldName: "key", value: "synthetic-original", security: .standard)
        try meta.save(.init(credentials: ["fixture": credential()]))
        request(create: false)
        XCTAssertEqual(results.last?.errorCode, .valueExists)
        let before = io.blob
        XCTAssertEqual(io.blob, before); XCTAssertEqual(clipboard.reads, 0)
        io.blob = nil; request(create: false)
        XCTAssertEqual(results.last?.errorCode, .storageUnavailable)
        XCTAssertNil(io.blob); XCTAssertEqual(clipboard.reads, 0)
    }
    func testEmptyAndWriteFailureDoNotClearClipboardOrCreateMetadata() throws {
        clipboard.text = "  \n"; request(); controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .emptyClipboard)
        clipboard.text = "synthetic"; io.failWrites = true; request(); controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .storageUnavailable)
        XCTAssertEqual(clipboard.clears, 0); XCTAssertTrue(try meta.load().credentials.isEmpty)
    }

    func testOldConfirmationCannotApproveNextRequest() {
        var callbacks: [(Bool) -> Void] = []
        controller = ClipboardSaveController(service: service, metaStore: meta, clipboard: clipboard,
            now: { self.clock }, present: { _, callback in callbacks.append(callback) }, dismiss: {})
        request(); controller.cancel(); request()
        callbacks[0](true)
        XCTAssertEqual(io.writes, 0)
        XCTAssertTrue(controller.isPending)
        callbacks[1](true)
        XCTAssertEqual(io.writes, 1)
    }

    func testNewCredentialDoesNotInheritStaleReadGrants() throws {
        try GrantStore(directory: directory).addGrant(.init(credentialId: "fixture", duration: .always))
        request(); controller.resolve(approved: true)
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertFalse(results.last?.success ?? true)
    }

    func testOversizedClipboardRejectedAndTargetRaceNeverOverwrites() throws {
        clipboard.text = String(repeating: "x", count: 65_537)
        request(); controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .emptyClipboard)
        XCTAssertEqual(io.writes, 0)
        clipboard.text = "synthetic"; request()
        try service.save(credentialId: "fixture", fieldName: "key", value: "synthetic-other", security: .strict)
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .valueExists)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-other")
    }

    func testMetadataCommitFailurePreservesValueAndNeverReportsSuccess() throws {
        io.afterWrite = {
            try FileManager.default.createDirectory(at: self.meta.fileURL, withIntermediateDirectories: false)
        }
        request(); controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .metadataCommitFailed)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-import")
        XCTAssertEqual(clipboard.clears, 0)
    }

    func testDisconnectedSocketIsDetectedWithoutReadingPayload() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]) }
        XCTAssertTrue(IPCServer.isClientConnected(fds[0]))
        close(fds[1])
        XCTAssertFalse(IPCServer.isClientConnected(fds[0]))
    }

    // MARK: 【真实事故】2026-09-13 剪贴板被覆盖，存进去的是一段提示词

    /// 调用方可以声明它期待的形状。对不上就拒绝入库——这是唯一能确定性拦下那次事故的检查：
    /// 一把 ed25519 私钥（Base64、32 字节）和一段中文提示词，形状差了十万八千里。
    func test声明的形状对不上就拒绝入库() throws {
        clipboard.text = "请你帮我把这个值存进 KeyKeeper，注意不要读取它的内容。"
        request(expect: "base64:32")
        controller.resolve(approved: true)

        XCTAssertEqual(results.first?.success, false)
        XCTAssertEqual(results.first?.errorCode, .shapeMismatch)
        XCTAssertEqual(io.writes, 0, "拒绝就是一个字节都不能写")
        XCTAssertNil(try? meta.load().credentials["fixture"])
        XCTAssertEqual(clipboard.clears, 0, "没存成功就别清空用户的剪贴板")
        XCTAssertEqual(results.first?.shape, ValueShape.of(clipboard.text!),
                       "拒绝时把实际形状告诉调用方，它才知道自己贴错了什么")
    }

    func test声明的形状对得上就照常入库() throws {
        let key = Data(repeating: 3, count: 32).base64EncodedString()
        clipboard.text = key
        request(expect: "base64:32")
        controller.resolve(approved: true)

        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), key)
        XCTAssertEqual(results.first?.shape?.base64DecodedBytes, 32)
    }

    /// 声明本身写错了，也是拒绝，不是放行。
    func test看不懂的声明一律拒绝() throws {
        request(expect: "一把密钥")
        XCTAssertEqual(results.first?.errorCode, .invalidExpectation)
        XCTAssertFalse(controller.isPending, "连弹窗都不该弹")
        XCTAssertEqual(clipboard.reads, 0)
    }

}
