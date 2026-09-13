import XCTest
@testable import KeyKeeperCore

/// 签名只在 App 这一侧查是不够的：`keykeeper get` / `keykeeper run` 在**命令行进程里**
/// 直接读 meta.json、直接把明文字段的值交出去。审计里那一招（把 `secret: true` 翻成 false
/// 再塞个值）走的正是这条路。命令行读不到钥匙串里的签名密钥（那会弹密码框），所以它去问
/// App：这份 meta.json 还是你写的那份吗？
final class MetadataIntegrityProtocolTests: XCTestCase {
    func test请求和回应能过IPC() throws {
        let request = IPCRequest.metadataIntegrity(MetadataIntegrityRequest())
        guard case .metadataIntegrity = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(request)) else {
            return XCTFail("请求没能原样解回来")
        }
        for verdict in [MetadataIntegrityResponse.Verdict.intact, .unsigned, .tampered] {
            let response = IPCResponse.metadataIntegrity(MetadataIntegrityResponse(verdict: verdict))
            guard case .metadataIntegrity(let decoded) = try JSONDecoder().decode(
                IPCResponse.self, from: JSONEncoder().encode(response)) else { return XCTFail() }
            XCTAssertEqual(decoded.verdict, verdict)
        }
    }

    /// 命令行交出明文值之前的判定。被改过的一律不交；问不到 App 的也不交——否则攻击者把
    /// App 进程杀掉就能绕过去。
    func test明文值只在确认完好时才交出去() {
        XCTAssertTrue(PlainValuePolicy.mayServe(.intact))
        XCTAssertTrue(PlainValuePolicy.mayServe(.unsigned), "这台机器还没开始签过，老文件照常")
        XCTAssertFalse(PlainValuePolicy.mayServe(.tampered))
        XCTAssertFalse(PlainValuePolicy.mayServe(nil), "问不到 App 就不交")
    }
}
