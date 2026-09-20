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
}
