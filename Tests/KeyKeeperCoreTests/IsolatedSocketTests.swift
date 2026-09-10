import XCTest
@testable import KeyKeeperCore

final class IsolatedSocketTests: XCTestCase {
    func testOverrideRequiresBothIsolatedStoresAndABoundedSocket() {
        let standard = IPCConstants.resolveSocketPath(environment: [:])
        var environment = ["KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-synthetic.sock"]
        XCTAssertEqual(IPCConstants.resolveSocketPath(environment: environment), standard)
        environment[KeyKeeperPaths.dataDirectoryEnvironmentKey] = "/private/tmp/synthetic"
        environment[SecItemBlobIO.serviceEnvironmentKey] = "com.keykeeper.test.synthetic"
        XCTAssertEqual(IPCConstants.resolveSocketPath(environment: environment), environment["KEYKEEPER_TEST_SOCKET"])
        environment["KEYKEEPER_TEST_SOCKET"] = "/tmp/keykeeper-test-../elsewhere/socket"
        XCTAssertEqual(IPCConstants.resolveSocketPath(environment: environment), standard)
    }
}
