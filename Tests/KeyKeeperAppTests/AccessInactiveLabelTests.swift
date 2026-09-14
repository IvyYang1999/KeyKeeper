import XCTest
@testable import KeyKeeperApp

/// 【独立审计第二轮】失效的授权在列表里只少一个小绿点，看起来和有效的一样。
@MainActor
final class AccessInactiveLabelTests: XCTestCase {
    func test失效授权用文字写出来() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/KeyKeeperApp/AccessSection.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("L(\"No longer applies\")"))
        XCTAssertNotEqual(AppL10n.render("No longer applies", language: "zh-Hans"), "No longer applies")
    }
}
