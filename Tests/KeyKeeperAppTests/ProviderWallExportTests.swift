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
        for match in ProviderBrowser.familyMatches(query: "") {
            let family = match.family
            let category = ProviderBrowser.groups.first { $0.value.contains(family.markId) }?.key
            var row: [String: Any] = ["id": family.markId, "name": family.name,
                                      "category": category.map { String(describing: $0) } ?? "",
                                      "variants": match.matched.count,
                                      "brand": ProviderMarks.brandHexes[family.markId] ?? "6E6E73"]
            if let mark = ProviderMarks.marks[family.markId], mark.systemSymbolName == nil {
                row["template"] = mark.isTemplate
                row["viewBox"] = mark.viewBox
                row["brand"] = mark.brandHex
                if let svg = mark.svgBody { row["svg"] = svg }
                if let png = mark.pngBase64 { row["png"] = png }
            } else {
                // No provider-sourced artwork: the same coloured lettermark the app draws.
                row["letter"] = ProviderMarks.letter(for: family.markId)
            }
            rows.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: output))
        XCTAssertEqual(rows.count, ProviderBrowser.familyMatches(query: "").count)
    }
}
