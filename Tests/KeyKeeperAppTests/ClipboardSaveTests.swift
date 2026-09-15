import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import CryptoKit
import Darwin
import KeyKeeperTestSupport

@MainActor private final class SaveTestClipboard: ClipboardSaveSource {
    var changeCount = 1
    var text: String? = "synthetic-import"
    var reads = 0
    /// Masked looks for the prompt; not a read of the value into the save path.
    var previews = 0
    var clears = 0
    var isSystemClipboard = true
    var copiedAt: Date? = Date(timeIntervalSince1970: 1_000)
    /// Simulates the clipboard being replaced during the read itself.
    var mutateOnRead: (() -> Void)?
    func readText() -> String? { reads += 1; mutateOnRead?(); return text }
    func preview() -> ClipboardPreview? { previews += 1; return text.map { var p = ClipboardPreview.masked($0); p.copiedAt = copiedAt; return p } }
    func clearIfUnchanged(since count: Int) {
        if count == changeCount { text = nil; changeCount += 1; clears += 1 }
    }
}

@MainActor final class ClipboardSaveTests: XCTestCase {
    private var directory: URL!
    private var meta: MetaStore!
    private var io: FakeKeychainIO!
    private var service: KeychainCredentialService!
    private var clipboard: SaveTestClipboard!
    private var controller: ClipboardSaveController!
    private var approvals: ApprovalStore!
    private var results: [ClipboardSaveResponse] = []
    private var clock = Date()
    private var connected = true
    private var updates: [ClipboardSaveController.Presentation] = []

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("clipboard-save-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        meta = MetaStore(directory: directory)
        io = FakeKeychainIO()
        service = KeychainCredentialService(store: KeychainBlobStore(io: io, loadMetadata: { try self.meta.load() }))
        clipboard = SaveTestClipboard()
        approvals = ApprovalStore.inMemory()
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: approvals, clipboard: clipboard,
            now: { self.clock }, present: { _, _ in }, update: { self.updates.append($0) }, dismiss: {})
        results = []; connected = true
    }
    override func tearDownWithError() throws {
        controller.cancel()
        controller = nil
        try FileManager.default.removeItem(at: directory)
    }
    private func request(create: Bool = true, expect: String? = nil, useCurrentClipboard: Bool = true) {
        controller.receive(.init(credentialId: "fixture", fieldName: "key", create: create, expect: expect,
                                 useCurrentClipboard: useCurrentClipboard),
            callerName: "Test caller",
            isConnected: { self.connected }, completion: { self.results.append($0) })
    }
    /// 复制一次：内容变了，changeCount 也跟着涨。`seen` 是「窗口刷新过、人看到了」——
    /// 默认如此；点击前一瞬换掉的内容传 false。
    private func copyToClipboard(_ text: String, seen: Bool = true) {
        clipboard.text = text
        clipboard.changeCount += 1
        if seen { controller.tick() }
    }
    private func credential() -> Credential {
        .init(label: "Existing", notes: "keep", links: [], fields: ["key": .init(secret: true)],
            security: .standard, created: "2026-01-01", updated: "2026-01-01")
    }
    private func prepareReplacement(expect: String = "chars:16") throws {
        try service.save(credentialId: "fixture", fieldName: "key", value: "old-fixture", security: .standard)
        try meta.save(.init(credentials: ["fixture": credential()]))
        controller.receive(.init(credentialId: "fixture", fieldName: "key", expect: expect,
                                 replaceExisting: true), callerName: "Test",
            isConnected: { self.connected }, completion: { self.results.append($0) })
    }

    func testExplicitReplacementPreservesMetadataAndOtherValues() throws {
        try prepareReplacement()
        let metadata = try Data(contentsOf: meta.fileURL)
        try service.save(credentialId: "other", fieldName: "key", value: "keep-fixture", security: .strict)
        copyToClipboard("synthetic-import")
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-import")
        XCTAssertEqual(try service.retrieve(credentialId: "other", fieldName: "key"), "keep-fixture")
        XCTAssertEqual(try Data(contentsOf: meta.fileURL), metadata)
    }

    func testReplacementWrongShapeOrConcurrentEditPreservesOldValue() throws {
        try prepareReplacement()
        copyToClipboard("wrong")
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .shapeMismatch)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "old-fixture")
        try prepareReplacement()
        try service.save(credentialId: "fixture", fieldName: "key", value: "newer-fixture", security: .standard)
        copyToClipboard("synthetic-import")
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .targetValueChanged)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "newer-fixture")
    }
    func testReplacementRefusalsPreserveBlobAndGrants() throws {
        // "twice" (a second copy while pending) is no longer a refusal: the prompt follows the clipboard.
        for failure in ["cancel", "expired", "disconnected", "write"] {
            try prepareReplacement()
            let original = io.blob
            try approvals.add(Approval(subject: .init(fingerprint: "unsigned:path=a", displayName: "a"),
                                       target: .credential(id: "fixture", fields: nil), duration: .always))
            let grants = try approvals.approvals(forCredential: "fixture").map(\.id)
            copyToClipboard("synthetic-import")
            if failure == "expired" { clock = clock.addingTimeInterval(91) }
            if failure == "disconnected" { connected = false }
            if failure == "twice" { copyToClipboard("second-copy-data") }
            if failure == "write" { io.failWrites = true }
            controller.resolve(approved: failure != "cancel")
            XCTAssertEqual(results.last?.success, false, failure)
            XCTAssertEqual(io.blob, original, failure)
            XCTAssertEqual(try approvals.approvals(forCredential: "fixture").map(\.id), grants)
            connected = true; io.failWrites = false
        }
    }

    func testPrivateSeedMustDeriveExpectedPublicKeyBeforeReplacement() throws {
        let seed = Data(repeating: 7, count: 32)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
        for matches in [false, true] {
            try service.save(credentialId: "fixture", fieldName: "key", value: "old-fixture", security: .standard)
            try meta.save(.init(credentials: ["fixture": credential()]))
            let publicKey = matches ? key.publicKey.rawRepresentation : Data(repeating: 1, count: 32)
            controller.receive(.init(credentialId: "fixture", fieldName: "key", expect: "base64:32",
                replaceExisting: true, expectedEd25519PublicKey: publicKey.base64EncodedString()),
                callerName: "Test", isConnected: { true }, completion: { self.results.append($0) })
            copyToClipboard(seed.base64EncodedString())
            controller.resolve(approved: true)
            XCTAssertEqual(results.last?.success, matches)
            XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"),
                           matches ? seed.base64EncodedString() : "old-fixture")
        }
    }

    func testReplacementDoesNotDependOnUnrelatedMissingValues() throws {
        try service.save(credentialId: "fixture", fieldName: "key", value: "old-fixture", security: .standard)
        try meta.save(.init(credentials: ["fixture": credential(), "missing": credential()]))
        controller.receive(.init(credentialId: "fixture", fieldName: "key", expect: "chars:16", replaceExisting: true),
            callerName: "Test", isConnected: { true }, completion: { self.results.append($0) })
        copyToClipboard("synthetic-import")
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        XCTAssertNotNil(try meta.load().credentials["missing"])
        XCTAssertThrowsError(try service.retrieve(credentialId: "missing", fieldName: "key"))
    }
    func testReplacementWireToServerToStoreRoundTrip() throws {
        try service.save(credentialId: "fixture", fieldName: "key", value: "old-fixture", security: .standard)
        try meta.save(.init(credentials: ["fixture": credential()]))
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), clipboard: clipboard,
            present: { info, approve in
                XCTAssertTrue(info.request.isReplacement)
                self.copyToClipboard("synthetic-import")
                approve(true)
            }, dismiss: {})
        let server = IPCServer(session: service, metaStore: meta, approvals: approvals, clipboardSaveController: controller)
        var sockets: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(sockets[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = ClipboardSaveRequest(credentialId: "fixture", fieldName: "key", expect: "chars:16", replaceExisting: true)
        try IPCMessage.writeMessage(fd: sockets[1], message: IPCRequest.clipboardSave(request))
        guard case .clipboardSave(let decoded) = IPCMessage.readMessage(fd: sockets[0], as: IPCRequest.self) else {
            close(sockets[0]); return XCTFail("wire decode failed")
        }
        server.handleClipboardSave(decoded, clientFd: sockets[0], peerPID: getpid(), callerName: "Fixture")
        guard case .clipboardSave(let response) = IPCMessage.readMessage(fd: sockets[1], as: IPCResponse.self) else {
            return XCTFail("response missing")
        }
        XCTAssertTrue(response.success)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-import")
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
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), present: { info, _ in shown = info }, dismiss: {})
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
        XCTAssertTrue(try approvals.approvals(forCredential: "fixture").isEmpty)
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
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), clipboard: clipboard,
            now: { self.clock }, present: { info, _ in
                XCTAssertTrue(info.fromBrowser); presentations += 1
            }, dismiss: {})
        let browserSource = SaveTestClipboard()
        browserSource.isSystemClipboard = false   // 浏览器粘贴页自己持有内容，不是共享的系统剪贴板
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
        request(); connected = false; controller.resolve(approved: true)
        XCTAssertEqual(results.last?.errorCode, .disconnected)
        XCTAssertEqual(clipboard.reads, 0); XCTAssertEqual(io.writes, 0)
        // A clipboard that moved unseen is not saved on that click; the prompt refreshes instead.
        connected = true
        request(); copyToClipboard("moved-while-pending", seen: false); controller.resolve(approved: true)
        XCTAssertEqual(results.count, 1, "第二个请求还挂着，没有结果")
        XCTAssertTrue(controller.isPending)
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
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: .inMemory(), clipboard: clipboard,
            now: { self.clock }, present: { _, callback in callbacks.append(callback) }, dismiss: {})
        request(); controller.cancel(); request()
        callbacks[0](true)
        XCTAssertEqual(io.writes, 0)
        XCTAssertTrue(controller.isPending)
        callbacks[1](true)
        XCTAssertEqual(io.writes, 1)
    }

    func testNewCredentialDoesNotInheritStaleReadGrants() throws {
        try approvals.add(Approval(subject: .init(fingerprint: "unsigned:path=old", displayName: "old"),
                                   target: .credential(id: "fixture", fields: nil), duration: .always))
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


    // MARK: 新鲜度的零点在「请求之后你有没有复制过」

    /// yyt 2026-09-14：「我明明已经复制了，AI 却说要它先发起、我再复制才有效……这个时候我已经把窗口关了」。
    /// 「请求之后恰好复制一次」把人绕晕了。现在剪贴板上有什么就存什么——先复制还是先发命令都行——
    /// 认对认错靠窗口：遮罩预览（头尾几个字符和长度）加复制时间，看一眼就知道是不是那把 key。
    func test已经复制好的内容直接可存_不要求请求之后再复制() throws {
        request(useCurrentClipboard: false)
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "synthetic-import")
    }

    func test弹窗上的预览只有头尾和长度_从不带完整值() throws {
        clipboard.text = "sk-live-0123456789abcdefghijklmnopqrstuvwxyz"
        var shown: ClipboardSaveController.Presentation?
        controller = ClipboardSaveController(service: service, metaStore: meta, approvals: approvals, clipboard: clipboard,
            now: { self.clock }, present: { info, _ in shown = info }, update: { _ in }, dismiss: {})
        request()
        let preview = try XCTUnwrap(shown?.preview)
        XCTAssertEqual(preview.masked, "sk-l…xyz")
        XCTAssertEqual(preview.shape.characters, 44)
        XCTAssertEqual(preview.copiedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(clipboard.previews, 1, "预览看一次，只算头尾和长度，不留全文")
        XCTAssertEqual(clipboard.reads, 0, "值本身要到批准之后才读")
    }

    /// 窗口开着的时候又复制了别的东西：预览跟着变，存的是人看过的那份。
    func test弹窗期间再复制_预览刷新_存看过的那份() throws {
        request()
        copyToClipboard("the-second-copy-is-the-real-key-here")
        XCTAssertEqual(updates.last?.preview?.masked, "the-…ere")
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "the-second-copy-is-the-real-key-here")
        XCTAssertEqual(updates.count, 1, "没变就不刷新")
    }

    /// 【独立审计 2026-09-14】预览每秒刷新一次；点击前那不到一秒里被换掉的内容，人没看过，不能存。
    /// 这一下不算数：预览刷新、按钮重新冷静、请求还挂着，人再看一眼再点。
    func test点击前一瞬被换掉_不存_刷新预览让人再看() throws {
        request()
        copyToClipboard("swapped-in-right-before-the-click", seen: false)
        controller.resolve(approved: true)          // no tick in between: the person never saw this
        XCTAssertTrue(results.isEmpty, "请求还挂着")
        XCTAssertTrue(controller.isPending)
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(clipboard.reads, 0, "值没读")
        XCTAssertEqual(updates.last?.preview?.masked, "swap…ick", "预览已经换成新内容")
        controller.resolve(approved: true)          // second look, second click
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(try service.retrieve(credentialId: "fixture", fieldName: "key"), "swapped-in-right-before-the-click")
    }

    /// 读取的那一瞬间仍然要稳定：读之前和读之后必须是同一份内容。
    func test读取窗口内被改掉仍然拒绝() throws {
        request()
        clipboard.mutateOnRead = { self.clipboard.changeCount += 1 }
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.errorCode, .clipboardChanged)
        XCTAssertEqual(io.writes, 0)
    }

}

extension ClipboardSaveTests {
    /// 【独立审计 2026-09-13】剪贴板新建凭据时，字段名直接来自 Agent 的请求，没过保留变量名检查。
    func test剪贴板新建不接受执行控制变量名() throws {
        controller.receive(.init(credentialId: "fixture", fieldName: "dyld-insert-libraries", create: true, expect: nil,
                                 useCurrentClipboard: true),
            callerName: "Test caller", isConnected: { true }, completion: { self.results.append($0) })
        XCTAssertFalse(controller.isPending, "不该弹窗让人批准一个注定危险的名字")
        XCTAssertEqual(results.first?.success, false)
        XCTAssertEqual(clipboard.reads, 0)
        XCTAssertEqual(io.writes, 0)
    }
}

extension ClipboardSaveTests {
    func test按Agent建议的保护方式和过期日新建() throws {
        controller.receive(.init(credentialId: "fixture", fieldName: "key", create: true, useCurrentClipboard: true,
                                 security: .standard, expires: "2026-12-31"),
            callerName: "Test caller", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.success, true)
        let saved = try XCTUnwrap(meta.load().credentials["fixture"])
        XCTAssertEqual(saved.security, .standard)
        XCTAssertEqual(saved.expires, "2026-12-31")
    }
}

// MARK: - 2026-09-15 服务商模板：保存后 KeyKeeper 自己验证，值不经过 Agent

extension ClipboardSaveTests {
    @MainActor private func providerController(probe: @escaping @Sendable (ProviderValidation, String) async -> CredentialValidation) -> ClipboardSaveController {
        ClipboardSaveController(service: service, metaStore: meta, approvals: approvals, clipboard: clipboard,
            now: { self.clock }, present: { _, _ in }, update: { _ in }, dismiss: {}, probe: probe)
    }

    func test新智谱保存一份值并保留新旧SDK环境变量() throws {
        controller = providerController { _, _ in .valid }
        controller.receive(.init(credentialId: "zhipu-fixture", fieldName: "zai-api-key", create: true, provider: "zhipu-cn"),
            callerName: "Test", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, true)
        let saved = try XCTUnwrap(meta.load().credentials["zhipu-fixture"])
        XCTAssertEqual(saved.fields.count, 1)
        XCTAssertEqual(saved.environmentNames(forField: "zai-api-key"), ["ZAI_API_KEY", "ZHIPUAI_API_KEY"])
        XCTAssertEqual(saved.resolveFieldName("zhipuai-api-key"), "zai-api-key")
        XCTAssertEqual(saved.provider, "zhipu-cn")
        XCTAssertEqual(io.writes, 1)
    }

    func test不存在的服务商不能静默当作普通密钥保存() {
        controller.receive(.init(credentialId: "fixture", fieldName: "key", create: true, provider: "not-a-real-provider"),
            callerName: "Test", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, false)
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(clipboard.reads, 0)
    }

    func test真实服务商也不能保存不属于模板的字段() {
        controller.receive(.init(credentialId: "fixture", fieldName: "wrong-key", create: true, provider: "zhipu-cn"),
            callerName: "Test", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        XCTAssertEqual(results.last?.success, false)
        XCTAssertEqual(io.writes, 0)
        XCTAssertEqual(clipboard.reads, 0)
    }

    func test带模板保存_保存后用只读请求验证_结果回给调用方_值只进请求头() async throws {
        let value = "sk-proj-" + String(repeating: "x", count: 100)
        clipboard.text = value
        nonisolated(unsafe) var probed: (String, String)?
        controller = providerController { validation, value in probed = (validation.url, value); return .valid }
        controller.receive(.init(credentialId: "openai", fieldName: "openai-api-key", create: true, provider: "openai"),
            callerName: "codex", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        for _ in 0..<50 where results.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.validation, .valid)
        XCTAssertEqual(probed?.0, "https://api.openai.com/v1/models")
        XCTAssertEqual(probed?.1, value, "探测用的就是存进去的值")
        XCTAssertNil(clipboard.text, "存完剪贴板清掉")
        XCTAssertEqual(try meta.load().credentials["openai"]?.provider, "openai")
        XCTAssertEqual(try service.retrieve(credentialId: "openai", fieldName: "openai-api-key"), value)
    }

    func test形状不像这家的key_写入前拒绝_说明不带值() throws {
        let wrongValue = "AKIA" + String(repeating: "x", count: 100)
        clipboard.text = wrongValue
        controller = providerController { _, _ in .valid }
        controller.receive(.init(credentialId: "telegram", fieldName: "telegram-bot-token", create: true, provider: "telegram"),
            callerName: "codex", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.errorCode, .shapeMismatch)
        let detail = try XCTUnwrap(results.first?.detail)
        XCTAssertTrue(detail.contains("documented format"), detail)
        XCTAssertFalse(detail.contains(wrongValue), "shape errors must never echo the clipboard value")
        XCTAssertEqual(io.writes, 0)
        XCTAssertNil(try? meta.load().credentials["telegram"])
    }

    func test验证期间不算超时_验证不可达也算保存成功() async throws {
        clipboard.text = "sk-ant-" + String(repeating: "y", count: 80)
        controller = providerController { _, _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return .unreachable
        }
        controller.receive(.init(credentialId: "anthropic", fieldName: "anthropic-api-key", create: true, provider: "claude"),
            callerName: "codex", isConnected: { true }, completion: { self.results.append($0) })
        controller.resolve(approved: true)
        clock = clock.addingTimeInterval(120)
        controller.tick()   // the 90 s deadline must not fire while the probe is running
        for _ in 0..<50 where results.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.validation, .unreachable)
    }

    func test没有模板_照旧_验证标记为skipped() throws {
        request()
        controller.resolve(approved: true)
        XCTAssertEqual(results.first?.success, true)
        XCTAssertEqual(results.first?.validation, .skipped)
    }

    /// Catalog rows are data, but every text provider must still cross the real shared App path:
    /// validate target → inspect shape → write the isolated blob → commit provider metadata →
    /// return a validation verdict. Values are generated fixtures and never touch macOS Keychain.
    func testEveryTextProviderCrossesTheIsolatedAppSavePath() async throws {
        let templates = ProviderCatalog.all.filter { $0.primaryField.kind == .secretText }
        XCTAssertGreaterThan(templates.count, 30)

        for template in templates {
            results = []
            let field = template.primaryField
            let prefix = field.prefixes.first ?? ""
            let count = max(field.minChars ?? 24, prefix.count + 8)
            let value = template.id == "telegram"
                ? "123456789:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi"
                : prefix + String(repeating: "x", count: count - prefix.count)
            XCTAssertNil(template.shapeProblem(for: value), template.id)
            clipboard.text = value
            controller = providerController { _, _ in .valid }
            controller.receive(.init(credentialId: template.id, fieldName: field.name,
                                     create: true, provider: template.id),
                callerName: "isolated-provider-e2e", isConnected: { true },
                completion: { self.results.append($0) })
            controller.resolve(approved: true)
            for _ in 0..<50 where results.isEmpty {
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            XCTAssertEqual(results.first?.success, true, template.id)
            XCTAssertEqual(try meta.load().credentials[template.id]?.provider, template.id, template.id)
            XCTAssertEqual(try service.retrieve(credentialId: template.id, fieldName: field.name), value, template.id)
        }
    }
}
