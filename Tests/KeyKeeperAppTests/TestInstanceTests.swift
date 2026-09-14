import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

/// 隔离实例的开关（自动批准、退出时清钥匙串）只在完整的隔离三件套下存在。
/// 单独一个环境变量对正式实例不能有任何作用——否则它就是一根谁都能拉的杆子。
final class TestInstanceTests: XCTestCase {
    private let triple = ["KEYKEEPER_DATA_DIR": "/tmp/kk-e2e/data",
                          "KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.e2e",
                          "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-e2e.sock"]

    func test没有三件套就什么开关都没有() {
        for env in [[:], ["KEYKEEPER_TEST_AUTO_APPROVE": "always"],
                    ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.e2e", "KEYKEEPER_TEST_AUTO_APPROVE": "always"],
                    ["KEYKEEPER_DATA_DIR": "/tmp/x", "KEYKEEPER_TEST_AUTO_APPROVE": "always"]] {
            XCTAssertFalse(TestInstance.isIsolated(environment: env), env.description)
            XCTAssertNil(TestInstance.autoApprove(environment: env), env.description)
            XCTAssertTrue(TestInstance.ownedKeychainServices(environment: env).isEmpty, env.description)
        }
    }

    func test三件套齐了才有开关且只碰测试条目() {
        XCTAssertTrue(TestInstance.isIsolated(environment: triple))
        XCTAssertNil(TestInstance.autoApprove(environment: triple), "没要求自动批准就不批")
        XCTAssertEqual(TestInstance.autoApprove(environment: triple.merging(["KEYKEEPER_TEST_AUTO_APPROVE": "once"]) { $1 }), .once)
        let owned = TestInstance.ownedKeychainServices(environment: triple)
        XCTAssertEqual(owned.count, 5, owned.description)
        XCTAssertTrue(owned.allSatisfy { $0.hasPrefix("com.keykeeper.test.e2e") }, owned.description)
        XCTAssertFalse(owned.contains(SecItemBlobIO.defaultService))
    }
}
