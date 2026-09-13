import XCTest
import Foundation
@testable import KeyKeeperCore

final class BrowserHostRegistrationTests: XCTestCase {
    func testRegistrationIsExactOriginAbsoluteHostAndCreateOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-host-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = String(repeating: "a", count: 32)
        let target = root.appendingPathComponent("host.json")
        let bytes = try BrowserHostRegistration.manifest(extensionID: id, launcher: "/Applications/KeyKeeper.app/Contents/Resources/browser-native-host")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(object["allowed_origins"] as? [String], ["chrome-extension://" + id + "/"])
        XCTAssertThrowsError(try BrowserHostRegistration.manifest(extensionID: "*", launcher: "/tmp/host"))
        XCTAssertThrowsError(try BrowserHostRegistration.manifest(extensionID: id, launcher: "relative"))
        try BrowserHostRegistration.install(bytes, at: target)
        try BrowserHostRegistration.install(bytes, at: target)
        XCTAssertThrowsError(try BrowserHostRegistration.install(Data("different".utf8), at: target))
        XCTAssertEqual(try Data(contentsOf: target), bytes)

        // 读得回来，界面才能说「已连接扩展 xxx」，而不是让人自己回忆有没有跑过那条命令。
        XCTAssertEqual(BrowserHostRegistration.registeredExtensionID(at: target), id)
        XCTAssertNil(BrowserHostRegistration.registeredExtensionID(at: root.appendingPathComponent("nope.json")))
        let foreign = root.appendingPathComponent("foreign.json")
        try Data("{\"allowed_origins\":[\"chrome-extension://not-an-id/\"]}".utf8).write(to: foreign)
        XCTAssertNil(BrowserHostRegistration.registeredExtensionID(at: foreign), "不是合法 ID 就当没注册")
    }

    /// Chrome 只认它自己 profile 目录下的这个文件名，路径写错等于功能不存在。
    func test注册文件落在Chrome自己的目录里() {
        let url = BrowserHostRegistration.manifestURL(home: URL(fileURLWithPath: "/Users/someone"))
        XCTAssertEqual(url.path,
            "/Users/someone/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.keykeeper.browser_sessions.json")
    }

    /// 扩展 ID 原来是 Chrome 按**安装路径**哈希出来的（GenerateIdForPath），所以它会随
    /// KeyKeeper.app 的位置变化——挪一次 app，原生主机里写死的 allowed_origins 立刻失配，
    /// 而且没有任何报错，只是再也连不上。manifest 里钉死 key 之后 ID 成了常量。
    func test扩展ID由manifest里的key算出来() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let manifest = root.appendingPathComponent("browser-extension/manifest.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: Data(contentsOf: manifest)) as? [String: Any])
        let key = try XCTUnwrap(object["key"] as? String, "manifest 里必须钉死 key，否则 ID 跟着路径走")

        let id = try XCTUnwrap(BrowserHostRegistration.extensionID(publicKeyBase64: key))
        XCTAssertEqual(id, "gmgmpachhmkfnngppibnmaekmdojkhch")
        XCTAssertNotNil(id.range(of: #"^[a-p]{32}$"#, options: .regularExpression))
        XCTAssertNoThrow(try BrowserHostRegistration.manifest(extensionID: id, launcher: "/tmp/host"))

        // Chrome 的算法：公钥 DER 的 SHA-256 前 16 字节，每个十六进制位 0→a … f→p
        XCTAssertNil(BrowserHostRegistration.extensionID(publicKeyBase64: "not base64!!"))
    }
}
