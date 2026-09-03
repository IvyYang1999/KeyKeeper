import XCTest
@testable import KeyKeeperCore

final class KeyKeeperPathsTests: XCTestCase {
    func test环境变量覆盖数据目录() {
        let url = KeyKeeperPaths.resolveApplicationSupportDirectory(
            environment: ["KEYKEEPER_DATA_DIR": "/tmp/kk-e2e/data"]
        )
        XCTAssertEqual(url.path, "/tmp/kk-e2e/data")
    }

    func test无覆盖时使用ApplicationSupport下的KeyKeeper() {
        let url = KeyKeeperPaths.resolveApplicationSupportDirectory(environment: [:])
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/KeyKeeper"))
        XCTAssertEqual(
            KeyKeeperPaths.resolveApplicationSupportDirectory(environment: ["KEYKEEPER_DATA_DIR": ""]).path,
            url.path
        )
    }
}
