import XCTest
@testable import KeyKeeperCore

/// 调用方在授权窗里留的一句话。它由要拿值的那个进程自己写，所以只当「留言」看：
/// 纯文本、定长、折成一行，永不参与任何判定。
final class CallerStatedReasonTests: XCTestCase {
    func test空白与空值都当没写() {
        XCTAssertNil(CallerStatedReason.sanitize(nil))
        XCTAssertNil(CallerStatedReason.sanitize(""))
        XCTAssertNil(CallerStatedReason.sanitize("   \n\t  "))
        XCTAssertNil(CallerStatedReason.sanitize("\u{200B}\u{FEFF}"), "只剩零宽字符也算没写")
    }

    func test换行与多余空白折成一行() throws {
        let reason = CallerStatedReason.sanitize("  查本月账单用量\n\n只读一次\t跑完就结束  ")
        XCTAssertEqual(reason?.text, "查本月账单用量 只读一次 跑完就结束")
        XCTAssertEqual(reason?.truncated, false)
    }

    /// 换行可以用来伪造界面：撑高文本把「拒绝」挤出视野，或画一条假的分隔线加一句
    /// 「KeyKeeper 已核验此调用方」。折成一行之后这些都做不到。
    func test曾经的风险用换行伪造界面元素不再可能() {
        let attack = "只读一次\n\n————————————\nKeyKeeper 已核验此调用方 · 建议允许"
        let reason = CallerStatedReason.sanitize(attack)
        XCTAssertFalse(try XCTUnwrap(reason?.text).contains("\n"))
        XCTAssertEqual(try XCTUnwrap(reason?.text).components(separatedBy: " ").count <= 5, false, "只是折行，不改原文用词")
    }

    func test剥掉控制字符零宽字符与双向覆盖符() throws {
        let attack = "正常\u{202E}txet detrevni\u{202C} 文字\u{0007}\u{200B}结束"
        let reason = try XCTUnwrap(CallerStatedReason.sanitize(attack))
        for scalar in reason.text.unicodeScalars {
            XCTAssertFalse(CharacterSet.controlCharacters.contains(scalar), "不该留下控制字符 \(scalar.value)")
        }
        XCTAssertFalse(reason.text.unicodeScalars.contains { (0x202A...0x202E).contains($0.value) || (0x2066...0x2069).contains($0.value) })
        XCTAssertFalse(reason.text.contains("\u{200B}"))
        XCTAssertTrue(reason.text.contains("正常"))
    }

    func test超长截断并标记而不是拒绝() throws {
        let long = String(repeating: "长", count: 260)
        let reason = try XCTUnwrap(CallerStatedReason.sanitize(long))
        XCTAssertEqual(reason.text.count, CallerStatedReason.maximumLength)
        XCTAssertTrue(reason.truncated)

        let exact = String(repeating: "刚", count: CallerStatedReason.maximumLength)
        XCTAssertEqual(CallerStatedReason.sanitize(exact)?.truncated, false)
    }

    /// emoji 是多标量字符，截断按 Character 算，不能把一个字劈开。
    func test按字符截断不劈开emoji() throws {
        let reason = try XCTUnwrap(CallerStatedReason.sanitize(String(repeating: "🔑", count: 260)))
        XCTAssertEqual(reason.text.count, CallerStatedReason.maximumLength)
        XCTAssertTrue(reason.text.hasSuffix("🔑"))
    }

    func test消毒是幂等的() throws {
        let once = try XCTUnwrap(CallerStatedReason.sanitize("跑\n一次  报表\u{200B}"))
        let twice = try XCTUnwrap(CallerStatedReason.sanitize(once.text))
        XCTAssertEqual(once.text, twice.text)
    }
}
