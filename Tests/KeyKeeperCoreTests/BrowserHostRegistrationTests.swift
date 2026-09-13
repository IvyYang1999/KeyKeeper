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
}
