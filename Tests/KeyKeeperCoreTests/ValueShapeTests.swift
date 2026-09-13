import XCTest
@testable import KeyKeeperCore

/// 【真实事故】2026-09-13：Agent 让 yyt 把 Sparkle 私钥复制到剪贴板，中间 yyt 又复制了
/// 一段 prompt 文本把它盖掉了。KeyKeeper 照单全收，报告「保存成功」，没有任何环节发现
/// 存进去的根本不是一把密钥。
///
/// 值本身永远不展示、不回传，但「形状」可以：多少字节、几行、是不是合法 Base64、
/// 解码出多少字节。那段 prompt 和一把 ed25519 私钥的形状差了十万八千里。
final class ValueShapeTests: XCTestCase {
    func test形状只描述不泄露() {
        let shape = ValueShape.of("hello world")
        XCTAssertEqual(shape.characters, 11)
        XCTAssertEqual(shape.bytes, 11)
        XCTAssertEqual(shape.lines, 1)
        XCTAssertTrue(shape.hasWhitespace)
        XCTAssertFalse(shape.hasNonASCII)
        XCTAssertNil(shape.base64DecodedBytes, "含空格不是合法 Base64")
    }

    func test中文和换行都数得出来() {
        let shape = ValueShape.of("第一行\n第二行")
        XCTAssertEqual(shape.characters, 7)
        XCTAssertEqual(shape.bytes, 19, "UTF-8 字节数，不是字符数")
        XCTAssertEqual(shape.lines, 2)
        XCTAssertTrue(shape.hasNonASCII)
    }

    func testBase64会解出字节数() {
        // 32 字节的 ed25519 种子，Base64 之后 44 个字符
        let seed = Data(repeating: 7, count: 32).base64EncodedString()
        let shape = ValueShape.of(seed)
        XCTAssertEqual(shape.characters, 44)
        XCTAssertEqual(shape.base64DecodedBytes, 32)
        XCTAssertNil(shape.hexDecodedBytes)
    }

    func test十六进制也认() {
        let shape = ValueShape.of("deadbeef")
        XCTAssertEqual(shape.hexDecodedBytes, 4)
    }

    /// 事故当天的两个东西：一把密钥 vs 一段提示词。形状一眼就能分开。
    func test密钥与提示词的形状完全不同() {
        let key = ValueShape.of(Data(repeating: 1, count: 64).base64EncodedString())
        let prompt = ValueShape.of("请你帮我把这个值存进 KeyKeeper，\n注意不要读取它的内容。")
        XCTAssertNotNil(key.base64DecodedBytes)
        XCTAssertNil(prompt.base64DecodedBytes)
        XCTAssertFalse(key.hasNonASCII)
        XCTAssertTrue(prompt.hasNonASCII)
        XCTAssertNotEqual(key.lines, prompt.lines)
    }

    // MARK: 调用方可以声明它期待的形状

    func test声明能解析也能判定() throws {
        let base64_32 = try XCTUnwrap(ValueExpectation.parse("base64:32"))
        XCTAssertTrue(base64_32.matches(ValueShape.of(Data(repeating: 9, count: 32).base64EncodedString())))
        XCTAssertFalse(base64_32.matches(ValueShape.of(Data(repeating: 9, count: 64).base64EncodedString())))
        XCTAssertFalse(base64_32.matches(ValueShape.of("请你帮我把这个值存进 KeyKeeper")))

        XCTAssertTrue(try XCTUnwrap(ValueExpectation.parse("bytes:11")).matches(ValueShape.of("hello world")))
        XCTAssertTrue(try XCTUnwrap(ValueExpectation.parse("chars:7")).matches(ValueShape.of("第一行\n第二行")))
        XCTAssertTrue(try XCTUnwrap(ValueExpectation.parse("hex:4")).matches(ValueShape.of("deadbeef")))
        XCTAssertTrue(try XCTUnwrap(ValueExpectation.parse("base64")).matches(ValueShape.of("aGVsbG8=")))
    }

    /// 声明写错了只会导致拒绝入库，不会放行更多东西——所以可以让调用方随便写。
    func test看不懂的声明一律拒绝而不是放行() {
        XCTAssertNil(ValueExpectation.parse("whatever"))
        XCTAssertNil(ValueExpectation.parse("bytes:"))
        XCTAssertNil(ValueExpectation.parse("bytes:-1"))
        XCTAssertNil(ValueExpectation.parse("base64:0"))
        XCTAssertNil(ValueExpectation.parse(""))
        XCTAssertNil(ValueExpectation.parse("bytes:99999999999999999999"))
    }
}
