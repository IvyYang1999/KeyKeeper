import XCTest
import Foundation
@testable import KeyKeeperCLI

final class BrowserHostInstallTests: XCTestCase {
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
    }
}
