import XCTest
@testable import KeyKeeperCore

/// 【安全审计 2026-09-13】主凭据库的钥匙串 service 名可以由环境变量直接指定，**没有任何
/// 门**——而它的两个同类口子（IPC socket、登录态存储）都要求「三件套齐全且形如测试用」
/// 才认。发布出去的二进制里留一个「换个库来读」的口子，即便当下不构成提权，也是个不该
/// 有的不一致。
final class KeychainServiceGateTests: XCTestCase {
    func test没有环境变量时用正式库() throws {
        XCTAssertEqual(try SecItemBlobIO.serviceName(environment: [:]), "com.keykeeper.credentials")
    }

    /// 测试用的三件套齐全才认，而且名字必须落在测试命名空间里。
    func test测试三件套齐全才认() throws {
        let ok = [
            "KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.fixture",
            "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-abc.sock",
            "KEYKEEPER_DATA_DIR": "/tmp/keykeeper-test-abc",
        ]
        XCTAssertEqual(try SecItemBlobIO.serviceName(environment: ok), "com.keykeeper.test.fixture")
    }

    func test缺一件或名字不对都拒绝() {
        let cases: [[String: String]] = [
            ["KEYKEEPER_KEYCHAIN_SERVICE": "com.someone.else"],
            ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.credentials"],
            ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.fixture"],
            ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.fixture",
             "KEYKEEPER_TEST_SOCKET": "/tmp/somewhere-else.sock"],
            ["KEYKEEPER_DATA_DIR": "/tmp/keykeeper-test-abc"],
        ]
        for environment in cases {
            XCTAssertThrowsError(try SecItemBlobIO.serviceName(environment: environment), "\(environment)")
        }
    }
}
