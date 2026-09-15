import XCTest
@testable import KeyKeeperCore

final class IsolatedSocketTests: XCTestCase {
    /// 【曾经的 bug】只要隔离三件套里有一个写错，CLI 就退回正式 socket，把合成测试值写进了真人库。
    /// 错误的测试环境必须得到一个仅本进程可见的死路，绝不能等价于“没有测试环境”。
    func test无效隔离环境绝不回退正式Socket() {
        let production = IPCConstants.resolveSocketPath(environment: [:])
        let partial = ["KEYKEEPER_TEST_SOCKET": "/tmp/not-a-keykeeper-test.sock"]
        let resolved = IPCConstants.resolveSocketPath(environment: partial)
        XCTAssertNotEqual(resolved, production)
        XCTAssertTrue(resolved.hasPrefix("/tmp/keykeeper-test-invalid-"), resolved)
        XCTAssertEqual(resolved, IPCConstants.resolveSocketPath(environment: partial), "同一进程内必须稳定")
    }

    func testOverrideRequiresBothIsolatedStoresAndABoundedSocket() {
        let standard = IPCConstants.resolveSocketPath(environment: [:])
        var environment = ["KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-synthetic.sock"]
        XCTAssertNotEqual(IPCConstants.resolveSocketPath(environment: environment), standard)
        environment[KeyKeeperPaths.dataDirectoryEnvironmentKey] = "/private/tmp/synthetic"
        environment[SecItemBlobIO.serviceEnvironmentKey] = "com.keykeeper.test.synthetic"
        XCTAssertEqual(IPCConstants.resolveSocketPath(environment: environment), environment["KEYKEEPER_TEST_SOCKET"])
        environment["KEYKEEPER_TEST_SOCKET"] = "/tmp/keykeeper-test-../elsewhere/socket"
        XCTAssertNotEqual(IPCConstants.resolveSocketPath(environment: environment), standard)
    }
}
