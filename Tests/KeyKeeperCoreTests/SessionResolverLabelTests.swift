import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-13：授权窗上「来源：未知终端」看着像是「我们不知道是哪个终端」，
/// 但真相是这个调用方压根没有终端会话（SDK、IDE、定时任务都是这样）。
/// 弹窗下面本来就写着「此调用方没有终端会话」，两句话必须说同一件事。
final class SessionResolverLabelTests: XCTestCase {
    func test没有终端会话时说的是没有而不是不知道() {
        let info = SessionResolver.resolve(environment: [:])
        XCTAssertNil(info.id)
        XCTAssertEqual(info.label, "No terminal session")
    }

    func test有终端会话时照旧给出可读的名字() {
        let info = SessionResolver.resolve(environment: ["TERM_SESSION_ID": "w0t1p0", "TERM_PROGRAM": "Apple_Terminal"])
        XCTAssertEqual(info.id, "w0t1p0")
        XCTAssertTrue(info.label.contains("Apple_Terminal"), info.label)
    }
}
