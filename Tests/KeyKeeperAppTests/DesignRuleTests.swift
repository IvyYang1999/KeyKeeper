import XCTest

/// The design rules from the 2026-11-08 UI review (UI-review-20261108, section 3), checked in
/// the source so a new screen cannot quietly bring back the old mix.
final class DesignRuleTests: XCTestCase {
    /// 盘点第三节第 1 条：全 App 一种输入框（灰色内嵌的 dsInput），不再混用白底描边的 roundedBorder。
    func test全App只用一种输入框() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Sources/KeyKeeperApp")
        var offenders: [String] = []
        for file in try FileManager.default.contentsOfDirectory(atPath: folder.path) where file.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            if source.contains(".roundedBorder") { offenders.append(file) }
        }
        XCTAssertEqual(offenders, [], "这些文件又用了描边输入框，改用 .dsInput()")
        // The provider picker's search box stays the native NSSearchField: it handles the arrow
        // keys, and without its own bezel the magnifier sits on top of the placeholder (tried 2026-11-08).
    }
}
