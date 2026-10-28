import Foundation
import Sparkle
import XCTest

/// Uses the shipped Sparkle settings reader with an isolated host bundle; no updater,
/// networking, windows or production preferences are created.
@MainActor
final class UpdateDefaultsTests: XCTestCase {
    func test真实Sparkle新用户读取新默认且已有选择优先() throws {
        let identifier = "com.keykeeper.update-settings-test.\(UUID().uuidString)"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(identifier + ".app")
        let contents = directory.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")), format: nil) as? [String: Any])
        plist["CFBundleIdentifier"] = identifier
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: directory))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        defer { defaults.removePersistentDomain(forName: identifier) }

        let fresh = SPUUpdaterSettings(hostBundle: bundle)
        XCTAssertTrue(fresh.automaticallyChecksForUpdates)
        XCTAssertTrue(fresh.automaticallyDownloadsUpdates)
        XCTAssertEqual(fresh.updateCheckInterval, 21_600)
        XCTAssertEqual(fresh.impatientUpdateCheckInterval, 86_400)

        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        defaults.set(false, forKey: "SUEnableAutomaticChecks")
        defaults.set(43_200, forKey: "SUScheduledCheckInterval")
        defaults.synchronize()
        let existing = SPUUpdaterSettings(hostBundle: bundle)
        XCTAssertFalse(existing.automaticallyDownloadsUpdates)
        XCTAssertFalse(existing.automaticallyChecksForUpdates)
        XCTAssertEqual(existing.updateCheckInterval, 43_200)
    }
}
