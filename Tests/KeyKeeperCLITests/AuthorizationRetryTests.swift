import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

/// 【独立审计 2026-09-13】命令行的自查说「有授权」（某条授权属于别的调用方），于是跳过弹窗；
/// App 严格核对后说「不是你的」，拒绝。结果是一条 strict 凭据**永远不弹窗、永远被拒**，
/// 报错里给的建议还做不到。自查只是体验判断，被 App 驳回时应该老老实实去申请一次授权。
final class AuthorizationRetryTests: XCTestCase {
    func test被App以无授权拒绝时改为申请一次() {
        XCTAssertTrue(RunCommand.shouldRequestAuthorizationAfterRefusal(
            IPCError.noAuthorization("No valid grant"), security: .strict, alreadyRetried: false))
    }

    func test只重试一次() {
        XCTAssertFalse(RunCommand.shouldRequestAuthorizationAfterRefusal(
            IPCError.noAuthorization(nil), security: .strict, alreadyRetried: true), "申请过还被拒，就是真的被拒")
    }

    func test别的错误和standard凭据不走这条路() {
        XCTAssertFalse(RunCommand.shouldRequestAuthorizationAfterRefusal(
            IPCError.vaultLocked, security: .strict, alreadyRetried: false))
        XCTAssertFalse(RunCommand.shouldRequestAuthorizationAfterRefusal(
            IPCError.noAuthorization(nil), security: .standard, alreadyRetried: false),
            "standard 凭据的授权窗由 App 自己排队弹出，不需要命令行再申请")
    }
}
