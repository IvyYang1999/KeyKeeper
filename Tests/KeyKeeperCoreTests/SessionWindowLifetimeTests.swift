import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-13：「到期不是砍掉窗口，是重新要一次授权」，做法选定为「冻结 + 覆盖层」。
///
/// 原来是 15 分钟到点直接 shutdown：窗口没了、数据擦了，Agent 半路丢掉全部上下文，而人
/// 可能只是去倒了杯水。现在到点先冻住——窗口还在、内容还在，盖一层要求重新授权。
final class SessionWindowLifetimeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = SessionWindowPolicy(limit: 900, graceAfterFreeze: 600)

    func test到点之前一直是活的() {
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: nil, now: start), .active)
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: nil, now: start.addingTimeInterval(899)), .active)
    }

    func test到点变成冻结而不是关闭() {
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: nil, now: start.addingTimeInterval(900)), .frozen)
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: nil, now: start.addingTimeInterval(5000)), .frozen)
    }

    /// 冻住之后没人理，也不能就这么一直开着——里面还坐着一个已登录的会话。
    func test冻结后无人理会最终还是要关掉() {
        let frozen = start.addingTimeInterval(900)
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: frozen, now: frozen.addingTimeInterval(599)), .frozen)
        XCTAssertEqual(policy.state(startedAt: start, frozenAt: frozen, now: frozen.addingTimeInterval(600)), .closed)
    }

    /// 重新授权 = 重新开始计时，不是在原来的终点上续命。
    func test重新授权后从头计时() {
        let renewed = start.addingTimeInterval(900)
        XCTAssertEqual(policy.state(startedAt: renewed, frozenAt: nil, now: renewed.addingTimeInterval(899)), .active)
        XCTAssertEqual(policy.state(startedAt: renewed, frozenAt: nil, now: renewed.addingTimeInterval(900)), .frozen)
    }

    /// 时长可设置，但不能设成「永远」或者荒唐的值。
    func test时长有上下限() {
        XCTAssertEqual(SessionWindowPolicy(limit: 5, graceAfterFreeze: 600).limit, SessionWindowPolicy.minimumLimit)
        XCTAssertEqual(SessionWindowPolicy(limit: 999_999, graceAfterFreeze: 600).limit, SessionWindowPolicy.maximumLimit)
        XCTAssertEqual(SessionWindowPolicy.default.limit, 900, "默认仍是 15 分钟，改动不该顺手改掉现状")
    }
}
