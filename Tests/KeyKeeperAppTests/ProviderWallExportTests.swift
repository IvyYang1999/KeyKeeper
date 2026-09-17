import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// Opt-in: writes the brand marks the website's logo wall draws, one entry per brand, from the
/// same provider-sourced artwork the app uses. KEYKEEPER_WALL_EXPORT=<file.json>
final class ProviderWallExportTests: XCTestCase {
    func test导出官网logo墙数据() throws {
        guard let output = ProcessInfo.processInfo.environment["KEYKEEPER_WALL_EXPORT"] else {
            throw XCTSkip("Opt-in export")
        }
        var rows: [[String: Any]] = []
        for family in ProviderBrowser.families {
            guard let mark = ProviderMarks.marks[family.markId], mark.systemSymbolName == nil else { continue }
            var row: [String: Any] = ["id": family.markId, "name": family.name, "brand": mark.brandHex,
                                      "template": mark.isTemplate, "viewBox": mark.viewBox]
            if let svg = mark.svgBody { row["svg"] = svg }
            if let png = mark.pngBase64 { row["png"] = png }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        XCTAssertGreaterThan(rows.count, 20)
    }
}
