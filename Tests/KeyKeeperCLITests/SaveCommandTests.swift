import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class SaveCommandTests: XCTestCase {
    func testReplacementRequiresFreshClipboardAndDistinctWireType() throws {
        let base = ["-c", "fixture", "--field", "key", "--from-clipboard", "--replace", "--expect", "chars:16"]
        let command = try SaveCommand.parse(base)
        XCTAssertTrue(command.request.isReplacement)
        XCTAssertThrowsError(try SaveCommand.parse(base + ["--create"]))
        // 2026-09-14：这个开关不再有含义，旧脚本带着它也不该报错。
        XCTAssertNoThrow(try SaveCommand.parse(base + ["--use-current-clipboard"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "key", "--from-clipboard", "--replace"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "key", "--from-browser", "--replace", "--expect", "chars:16"]))
        let data = try JSONEncoder().encode(IPCRequest.clipboardSave(command.request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "clipboardReplace")
        guard case .clipboardSave(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded, command.request)
        var downgraded = json
        downgraded["type"] = "clipboardSave"
        XCTAssertThrowsError(try JSONDecoder().decode(IPCRequest.self, from: JSONSerialization.data(withJSONObject: downgraded)))
    }
    func testSourceRequiresExplicitSymbolAndDistinctMetadataOnlyProtocol() throws {
        let base = ["-c", "fixture", "--field", "ADMIN_KEY", "--from-source", "/tmp/synthetic.py"]
        XCTAssertThrowsError(try SaveCommand.parse(base))
        XCTAssertThrowsError(try SaveCommand.parse(base + ["--python-symbol", "X;print(1)"]))
        XCTAssertThrowsError(try SaveCommand.parse(base + ["--python-symbol", "X", "--from-clipboard"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "key", "--from-browser", "--python-symbol", "X"]))
        let command = try SaveCommand.parse(base + ["--python-symbol", "ADMIN_KEY", "--create"])
        let request = SourceImportRequest(target: command.request, filePath: command.fromSource!, pythonSymbol: command.pythonSymbol!)
        let data = try JSONEncoder().encode(IPCRequest.sourceImport(request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "sourceImport")
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["target", "filePath", "pythonSymbol"])
        guard case .sourceImport(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded, request)
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(for: .sourceImport(request)))
    }
    func testFileImportOnlySendsPathAndTarget() throws {
        let command = try SaveCommand.parse(["-c", "fixture", "--field", "credentials-json", "--from-file", "/tmp/synthetic.json", "--create"])
        XCTAssertEqual(command.fromFile, "/tmp/synthetic.json")
        for extra in ["--from-browser", "--from-clipboard"] {
            XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "file", "--from-file", "/tmp/synthetic.json", extra]))
        }
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "file", "--from-file", "relative.json"]))
        let request = FileImportRequest(target: command.request, filePath: command.fromFile!)
        let data = try JSONEncoder().encode(IPCRequest.fileImport(request))
        guard case .fileImport(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded, request)
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(for: .fileImport(request)))
    }
    func testBrowserImportRequiresExactlyOneSourceAndMetadataOnlyIPC() throws {
        let command = try SaveCommand.parse(["-c", "fixture", "--field", "key", "--from-browser", "--create"])
        XCTAssertTrue(command.fromBrowser)
        XCTAssertTrue(command.request.create)
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "fixture", "--field", "key", "--from-browser", "--from-clipboard"]))
        let encoded = try JSONEncoder().encode(IPCRequest.browserImport(command.request))
        guard case .browserImport(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: encoded) else { return XCTFail() }
        XCTAssertEqual(decoded, command.request)
        let ready = IPCResponse.browserImportReady("http://127.0.0.1:12345/#synthetic-ticket")
        guard case .browserImportReady(let url) = try JSONDecoder().decode(IPCResponse.self, from: JSONEncoder().encode(ready)) else { return XCTFail() }
        XCTAssertEqual(url, "http://127.0.0.1:12345/#synthetic-ticket")
    }
    func testNoValueArgumentAndExplicitClipboardRequired() throws {
        let command = try SaveCommand.parse(["-c", "硅基流动", "--field", "key", "--from-clipboard"])
        XCTAssertEqual(command.request, .init(credentialId: "硅基流动", fieldName: "key"))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "key"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x", "--field", "key", "--from-clipboard", "--value", "synthetic"]))
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "x\nmisleading", "--field", "key", "--from-clipboard"]))
    }

    func testProtocolContainsOnlyTargetAndConstantResponse() throws {
        let request = ClipboardSaveRequest(credentialId: "fixture", fieldName: "key", create: true)
        let data = try JSONEncoder().encode(IPCRequest.clipboardSave(request))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(json["data"] as? [String: Any])
        // 请求里只有「存到哪儿」和「怎么收」——没有值、没有剪贴板文本、没有自称身份。
        XCTAssertEqual(Set(payload.keys), ["credentialId", "fieldName", "create", "useCurrentClipboard"])
        guard case .clipboardSave(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded, request)
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(for: .clipboardSave(request)))
        XCTAssertThrowsError(try IPCClient.decodeClipboardSaveResponse(.value(.init(success: false, errorCode: .invalidRequest))))
        XCTAssertEqual(try IPCClient.decodeClipboardSaveResponse(.clipboardSave(.init(success: true))), .init(success: true))
    }

    /// 【真实事故】2026-09-13：剪贴板在复制与保存之间被覆盖，存进去的是一段提示词，
    /// 而命令行只打印了一句「Saved.」。现在可以先声明形状，存完还会回报存了个什么形状。
    func test可以声明期待的形状并且形状会被回报() throws {
        let command = try SaveCommand.parse(["-c", "sparkle", "--field", "private-key",
                                             "--from-clipboard", "--expect", "base64:32"])
        XCTAssertEqual(command.request.expect, "base64:32")
        XCTAssertNoThrow(try command.request.validate())

        // 声明写错了，解析阶段就拒绝，连请求都不发出去
        XCTAssertThrowsError(try SaveCommand.parse(["-c", "sparkle", "--field", "k", "--from-clipboard", "--expect", "一把钥匙"]))

        // 形状随请求原样过 IPC
        let data = try JSONEncoder().encode(IPCRequest.clipboardSave(command.request))
        guard case .clipboardSave(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded.expect, "base64:32")

        XCTAssertEqual(SaveCommand.storedSummary(ValueShape.of(Data(repeating: 1, count: 32).base64EncodedString())),
                       "44 characters, Base64 (32 bytes)")
        XCTAssertEqual(SaveCommand.storedSummary(ValueShape.of("请把这个存进去\n第二行")),
                       "11 characters, 31 bytes, 2 lines, non-ASCII")
    }
}
