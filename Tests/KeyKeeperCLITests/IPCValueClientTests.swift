import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class IPCValueClientTests: XCTestCase {
    /// vaultLocked 只会来自旧 App（wire 兼容）；新模型没有 unlock，指引改为打开 App。
    func testVaultLockedStorageErrorStillDecodesWithActionableHint() {
        XCTAssertThrowsError(try IPCClient.decodeValueResponse(ValueResponse(
            success: false,
            error: "Credential vault is locked",
            errorCode: .keychainError,
            storageErrorCode: .vaultLocked
        ))) { error in
            guard case IPCError.vaultLocked = error else {
                return XCTFail("Expected IPCError.vaultLocked, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("Open the KeyKeeper app"))
            XCTAssertFalse(error.localizedDescription.contains("unlock"))
        }
    }

    func testVaultLockedProducesNonzeroCLIExitAndActionableStderr() {
        let error = IPCError.vaultLocked

        XCTAssertNotEqual(KeyKeeperCommand.exitCode(for: error), .success)
        XCTAssertTrue(
            KeyKeeperCommand.fullMessage(for: error).contains("Open the KeyKeeper app")
        )
    }

    func testVaultReadFailureTakesPriorityOverLegacyKeychainFallback() {
        XCTAssertThrowsError(try IPCClient.decodeValueResponse(ValueResponse(
            success: false,
            error: "Credential vault read failed",
            errorCode: .keychainError,
            storageErrorCode: .readFailed
        ))) { error in
            guard case IPCError.vaultReadFailed = error else {
                return XCTFail("Expected IPCError.vaultReadFailed, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.contains("Keychain"))
        }
    }

    func testVaultNotFoundUsesReadFailureDetailBeforeLegacyDeniedFallback() {
        XCTAssertThrowsError(try IPCClient.decodeValueResponse(ValueResponse(
            success: false,
            error: "Credential value not found",
            errorCode: .notFound,
            storageErrorCode: .readFailed
        ))) { error in
            guard case IPCError.vaultReadFailed = error else {
                return XCTFail("Expected vault read failure, got \(error)")
            }
        }
    }

    func testLegacyAppKeychainErrorStillUsesCompatibilityFallback() {
        XCTAssertThrowsError(try IPCClient.decodeValueResponse(ValueResponse(
            success: false,
            error: "legacy storage failure",
            errorCode: .keychainError
        ))) { error in
            guard case IPCError.keychainBlocked = error else {
                return XCTFail("Expected legacy keychain fallback, got \(error)")
            }
        }
    }

    func testGetAndRunParsersPreserveValueRequestArgumentsPrefixAndTTY() throws {
        let get = try GetCommand.parse(["credential-a", "token"])
        XCTAssertEqual(get.credentialId, "credential-a")
        XCTAssertEqual(get.fieldName, "token")

        let command = try RunCommand.parse([
            "-c", "first",
            "-c", "second",
            "--prefix", "KEYKEEPER_",
            "--tty",
            "--", "/usr/bin/env",
        ])

        XCTAssertEqual(command.credential, ["first", "second"])
        XCTAssertEqual(command.prefix, "KEYKEEPER_")
        XCTAssertTrue(command.tty)
        XCTAssertEqual(command.command, ["/usr/bin/env"])
        XCTAssertEqual(command.prefix + RunCommand.envVarName(from: "api-key"), "KEYKEEPER_API_KEY")
    }
}
