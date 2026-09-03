import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class IPCLaunchPolicyTests: XCTestCase {
    /// 决策 2026-07-20 ⑥：仅 unlock 可启动 App。
    func test只有unlock会拉起App() {
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(
            for: .sessionControl(SessionControlRequest(action: .unlock, passphrase: "phrase placeholder"))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(
            for: .sessionControl(SessionControlRequest(action: .lock))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(
            for: .sessionControl(SessionControlRequest(action: .status))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(
            for: .value(ValueRequest(credentialId: "c", fieldName: "f", sessionId: nil))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(
            for: .auth(AuthRequest(credentialId: "c", credentialLabel: "C", fieldNames: ["f"], sessionId: nil, sessionLabel: nil, pid: 1))
        ))
        XCTAssertFalse(IPCLaunchPolicy.shouldLaunchApp(for: .serviceRequests(ServiceRequestsListRequest())))
    }
}
