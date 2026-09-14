import XCTest
@testable import KeyKeeperCore

/// 【独立审计第二轮】整份比对用的是文件自己写的扩展 ID：把登记换成另一个扩展照样显示「已登记」；
/// 而 KeyKeeper 只是换了位置，却被说成「有人改过它」。
final class ManifestStateTests: XCTestCase {
    private let ours = String(repeating: "a", count: 32)
    private let theirs = String(repeating: "b", count: 32)
    private let launcher = "/Applications/KeyKeeper.app/Contents/Resources/browser-native-host"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-state-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(extensionID: String, launcher: String) throws -> URL {
        let url = dir.appendingPathComponent("host-\(UUID()).json")
        try BrowserHostRegistration.manifest(extensionID: extensionID, launcher: launcher).write(to: url)
        return url
    }

    func test登记给了别的扩展算被改过() throws {
        let url = try write(extensionID: theirs, launcher: launcher)
        XCTAssertEqual(BrowserHostRegistration.registrationState(at: url, expectedLauncher: launcher, expectedExtensionID: ours), .tampered)
    }

    func test只是KeyKeeper换了位置() throws {
        let url = try write(extensionID: ours, launcher: "/Users/me/Downloads/KeyKeeper.app/Contents/Resources/browser-native-host")
        XCTAssertEqual(BrowserHostRegistration.registrationState(at: url, expectedLauncher: launcher, expectedExtensionID: ours), .moved(ours))
        let elsewhere = try write(extensionID: ours, launcher: "/tmp/not-keykeeper")
        XCTAssertEqual(BrowserHostRegistration.registrationState(at: elsewhere, expectedLauncher: launcher, expectedExtensionID: nil), .tampered,
                       "指向任意别的程序仍然算被改过，不能说成挪了位置")
    }

    func test原样的登记完好() throws {
        let url = try write(extensionID: ours, launcher: launcher)
        XCTAssertEqual(BrowserHostRegistration.registrationState(at: url, expectedLauncher: launcher, expectedExtensionID: ours), .intact(ours))
        XCTAssertNil(BrowserHostRegistration.registrationState(at: dir.appendingPathComponent("none.json"),
                                                               expectedLauncher: launcher, expectedExtensionID: ours))
    }
}
