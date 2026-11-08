import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

final class BrowserImportPageTests: XCTestCase {
    func testBrowserPasteLifecycleStaysSecretSafeWithoutClipboardReadPermission() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "zh-Hans"] {
            let html = BrowserImportPage.html(request: .init(credentialId: "fixture", fieldName: "key", create: true), language: language)
            let process = Process(), input = Pipe(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", root.appendingPathComponent("scripts/test-browser-import-page.cjs").path]
            process.standardInput = input; process.standardOutput = output; process.standardError = output
            try process.run()
            input.fileHandleForWriting.write(Data(html.utf8)); try input.fileHandleForWriting.close()
            let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            let outputText = String(decoding: result, as: UTF8.self)
            XCTAssertEqual(process.terminationStatus, 0, "Browser lifecycle harness failed: \(outputText)")
            XCTAssertTrue(outputText.contains("BROWSER_PAGE_LIFECYCLE_OK"), outputText)
        }
    }

    /// 粘贴页每一句文案都有中文；不再有大写的「KEYKEEPER · 本机导入」小标题。
    func test粘贴页文案都有中文() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/BrowserImportPage.swift"), encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"[tj]\("([^"\\]*)"\)"#)
        var keys = pattern.matches(in: source, range: NSRange(source.startIndex..., in: source))
            .map { (source as NSString).substring(with: $0.range(at: 1)) }
        keys += ["Creates a new credential with Ask every time protection.",
                 "Adds a new secret field. Existing read permissions stay limited to the old fields.",
                 "Restores this missing field without changing its existing permissions."]
        XCTAssertGreaterThan(keys.count, 15)
        for key in keys {
            XCTAssertNotEqual(AppL10n.render(key, language: "zh-Hans"), key, key)
        }
        let html = BrowserImportPage.html(request: .init(credentialId: "fixture", fieldName: "key", create: true), language: "zh-Hans")
        XCTAssertFalse(html.contains("LOCAL IMPORT"))
        XCTAssertTrue(html.contains("在 Mac 上确认"))
    }
}
