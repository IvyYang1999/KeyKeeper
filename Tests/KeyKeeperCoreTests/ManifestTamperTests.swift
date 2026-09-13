import XCTest
@testable import KeyKeeperCore

/// 【独立审计 2026-09-13】注册文件复查只比了 path。改 type、name，界面照样说「已注册」；多加一个
/// 来源，则变成「未注册」且毫无警告。该比的是整份文件：它必须和我们会写出来的那份一模一样。
final class ManifestTamperTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private let launcher = "/Applications/KeyKeeper.app/Contents/Resources/browser-native-host"
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func write(_ mutate: (inout [String: Any]) -> Void) throws -> URL {
        let data = try BrowserHostRegistration.manifest(extensionID: id, launcher: launcher)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        mutate(&object)
        let url = dir.appendingPathComponent("host-\(UUID()).json")
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        return url
    }

    func test原样的注册文件是完好的() throws {
        let url = try write { _ in }
        XCTAssertEqual(BrowserHostRegistration.registration(at: url, expectedLauncher: launcher)?.intact, true)
    }

    func test改了type或name或多了字段算被篡改() throws {
        let mutations: [(inout [String: Any]) -> Void] = [
            { $0["type"] = "other" }, { $0["name"] = "com.evil.host" }, { $0["extra"] = true },
        ]
        for mutate in mutations {
            let url = try write(mutate)
            XCTAssertEqual(BrowserHostRegistration.registration(at: url, expectedLauncher: launcher)?.intact, false)
        }
    }

    func test多加一个来源算被篡改而不是未注册() throws {
        let other = "chrome-extension://" + String(repeating: "b", count: 32) + "/"
        let url = try write { $0["allowed_origins"] = ["chrome-extension://" + String(repeating: "a", count: 32) + "/", other] }
        let found = BrowserHostRegistration.registration(at: url, expectedLauncher: launcher)
        XCTAssertNotNil(found, "文件在、却被改过，不能报成「没注册」")
        XCTAssertEqual(found?.intact, false)
    }
}
