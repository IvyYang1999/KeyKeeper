import LocalAuthentication
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

    /// 【曾经的 bug】yyt 2026-09-13：「在授权弹窗点击 usePassword 之后，并没有填写 Password
    /// 的弹窗，而是直接消失了」。旧实现把 LAError.userFallback（用户选择改用密码）当成通过，
    /// 直接放行——任何人在这台机器前点两下就能绕开 Touch ID 拿到值。现在必须改用密码策略
    /// 再验一次，验过才放行。
    func test曾经的Bug选择改用密码不能直接放行() {
        XCTAssertEqual(
            AuthorizationView.AuthenticationOutcome.decide(success: false, code: .userFallback, devicePasswordAvailable: true),
            .askForDevicePassword)
        XCTAssertEqual(
            AuthorizationView.AuthenticationOutcome.decide(success: false, code: .biometryNotAvailable, devicePasswordAvailable: true),
            .askForDevicePassword)
        XCTAssertEqual(
            AuthorizationView.AuthenticationOutcome.decide(success: false, code: .biometryLockout, devicePasswordAvailable: true),
            .askForDevicePassword)

        // 没有设备密码可用时也绝不能放行，只能报错。
        for code in [LAError.Code.userFallback, .biometryNotAvailable, .biometryLockout] {
            let outcome = AuthorizationView.AuthenticationOutcome.decide(
                success: false, code: code, devicePasswordAvailable: false)
            XCTAssertNotEqual(outcome, .authorize, "\(code) 在没有密码可验时不能放行")
            guard case .failed = outcome else { return XCTFail("\(code) 应该报错，实际 \(outcome)") }
        }
    }

    func test验证通过才放行取消就是取消() {
        XCTAssertEqual(
            AuthorizationView.AuthenticationOutcome.decide(success: true, code: nil, devicePasswordAvailable: true),
            .authorize)
        for code in [LAError.Code.userCancel, .appCancel, .systemCancel] {
            XCTAssertEqual(
                AuthorizationView.AuthenticationOutcome.decide(success: false, code: code, devicePasswordAvailable: true),
                .cancelled, "\(code) 应该当作取消")
        }
        guard case .failed = AuthorizationView.AuthenticationOutcome.decide(
            success: false, code: .authenticationFailed, devicePasswordAvailable: true) else {
            return XCTFail("认证失败应该报错")
        }
    }

    /// 密码那一轮不再有「改用密码」的退路：再收到 fallback 只能算失败，不能递归也不能放行。
    func test密码轮里的回退不再升级() {
        let outcome = AuthorizationView.AuthenticationOutcome.decide(
            success: false, code: .userFallback, devicePasswordAvailable: true, isPasswordRound: true)
        XCTAssertNotEqual(outcome, .authorize)
        XCTAssertNotEqual(outcome, .askForDevicePassword)
    }

    /// 【曾经的 bug】yyt 2026-09-13 下午：「点击 usePassword 之后，还是会变成按指纹的弹窗，
    /// 再点一次 usePassword 才会变成输入密码的输入条」。第二轮用的是
    /// `.deviceOwnerAuthentication`——那个策略本来就先出 Touch ID，于是又回到原地。
    /// 密码轮必须是「只认密码」的那种提示，绝不能再走任何会弹指纹的策略。
    func test曾经的Bug密码轮绝不再弹指纹() throws {
        XCTAssertNil(AuthorizationView.AuthenticationRound.devicePasswordOnly.policy,
                     "密码轮一旦还挂着 LAPolicy，系统就会再弹一次 Touch ID")
        XCTAssertEqual(AuthorizationView.AuthenticationRound.devicePasswordOnly.accessControlFlags, .devicePasscode)
        XCTAssertEqual(AuthorizationView.AuthenticationRound.biometrics.policy, .deviceOwnerAuthenticationWithBiometrics)
        XCTAssertNil(AuthorizationView.AuthenticationRound.biometrics.accessControlFlags)
        XCTAssertNotNil(AuthorizationView.AuthenticationRound.devicePasswordOnly.accessControl(),
                        "只认密码的 SecAccessControl 必须能建出来，否则密码轮无路可走")
        XCTAssertTrue(AuthorizationView.AuthenticationRound.devicePasswordOnly.isPasswordRound)
        XCTAssertFalse(AuthorizationView.AuthenticationRound.biometrics.isPasswordRound)
    }
}
