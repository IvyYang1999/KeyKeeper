import XCTest

/// 界面层的两处问题，行为测试够不着（SwiftUI 视图、WebKit 窗口），用源码结构把规矩钉住。
final class PromptHonestyStructureTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// 【独立审计 2026-09-13】保存和登录态授权窗没有冷静期：正在路上的一次点击会落在刚弹出的窗上。
    func test保存和登录态授权窗有冷静期() throws {
        let trust = try source("Sources/KeyKeeperApp/TrustPrompt.swift")
        XCTAssertTrue(trust.contains(".disabled(!canConfirm)"))
        XCTAssertTrue(trust.contains("ApprovalReadiness.settleDelay"))
    }
}
