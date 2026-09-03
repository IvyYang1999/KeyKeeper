import XCTest
@testable import KeyKeeperApp

final class AuthenticationMethodTests: XCTestCase {
    func test无TouchID时退到设备密码而不是无验证() {
        XCTAssertEqual(
            AuthorizationView.AuthenticationMethod.choose(biometricsAvailable: false, devicePasswordAvailable: true),
            .devicePassword
        )
        XCTAssertEqual(
            AuthorizationView.AuthenticationMethod.choose(biometricsAvailable: true, devicePasswordAvailable: true),
            .biometrics
        )
        XCTAssertEqual(
            AuthorizationView.AuthenticationMethod.choose(biometricsAvailable: false, devicePasswordAvailable: false),
            .none
        )
    }

    func test按钮图标与实际验证方式一致() {
        XCTAssertEqual(AuthorizationView.AuthenticationMethod.biometrics.symbolName, "touchid")
        XCTAssertNotEqual(AuthorizationView.AuthenticationMethod.devicePassword.symbolName, "touchid")
        XCTAssertNotEqual(AuthorizationView.AuthenticationMethod.none.symbolName, "touchid")
        XCTAssertNil(AuthorizationView.AuthenticationMethod.none.policy)
    }
}
