import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class IPCLaunchPolicyTests: XCTestCase {
    /// 决策 2026-09-03：Keychain 存储下 App 即起即用，取值/授权请求按需拉起 App，
    /// cron 在重启后自愈；status 保持无副作用。（取代 2026-07-20 决策⑥）
    func test取值与授权请求会拉起App() {
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(
            for: .value(ValueRequest(credentialId: "c", fieldName: "f", sessionId: nil))
        ))
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(
            for: .auth(AuthRequest(credentialId: "c", credentialLabel: "C", fieldNames: ["f"], sessionId: nil, sessionLabel: nil, pid: 1))
        ))
    }

    func testStatus与请求列表不拉起App() {
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(
            for: .sessionControl(SessionControlRequest(action: .status))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(for: .serviceRequests(ServiceRequestsListRequest())))
    }
}
