import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class SaveCommandTests: XCTestCase {
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
        XCTAssertEqual(Set(payload.keys), ["credentialId", "fieldName", "create"])
        guard case .clipboardSave(let decoded) = try JSONDecoder().decode(IPCRequest.self, from: data) else { return XCTFail() }
        XCTAssertEqual(decoded, request)
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(for: .clipboardSave(request)))
        XCTAssertThrowsError(try IPCClient.decodeClipboardSaveResponse(.value(.init(success: false, errorCode: .invalidRequest))))
        XCTAssertEqual(try IPCClient.decodeClipboardSaveResponse(.clipboardSave(.init(success: true))), .init(success: true))
    }
}
