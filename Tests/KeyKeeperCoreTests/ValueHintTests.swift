import XCTest
import Security
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 值预览：只露后 4 位，短值一位都不露；只在 App 自己的列表里算，不写元数据、不走 IPC。
final class ValueHintTests: XCTestCase {
    func test长值只给后4位短值什么都不给() {
        XCTAssertEqual(ValueHint.suffix(of: "sk-synthetic-0000-a1Kk"), "a1Kk")
        XCTAssertEqual(ValueHint.suffix(of: "  ghp_synthetic9Zz\n"), "c9Zz", "首尾空白不算")
        XCTAssertEqual(ValueHint.suffix(of: "123456789012"), "9012", "刚好 12 位")
        XCTAssertNil(ValueHint.suffix(of: "12345678901"), "11 位的值（像密码）不露任何字符")
        XCTAssertNil(ValueHint.suffix(of: ""))
        XCTAssertEqual(ValueHint.suffix(of: "合成密钥合成密钥合成密钥尾巴四字"), "尾巴四字", "按字符算，不按字节")
    }

    func test概览和清单同一次免授权读取且只带后4位() throws {
        let io = FakeKeychainIO()
        let store = KeychainBlobStore(io: io)
        XCTAssertEqual(try store.inspectValueOverview(), CredentialValueOverview(names: [:]))
        io.blob = Data(#"{"version":1,"credentials":{"openai":{"api-key":"sk-synthetic-0000-a1Kk","pin":"1234"}}}"#.utf8)
        let overview = try store.inspectValueOverview()
        XCTAssertEqual(overview.names, try store.inspectValueInventory())
        XCTAssertEqual(overview.hints, ["openai": ["api-key": "a1Kk"]], "短值 pin 没有提示")
        io.readError = KeychainError.retrieveFailed(errSecInteractionNotAllowed)
        XCTAssertThrowsError(try store.inspectValueOverview(), "要弹授权才能读时直接失败，不弹")
        XCTAssertEqual(io.ordinaryReads, 0, "只走免交互读取")
        XCTAssertEqual(io.writes, 0)
    }
}
