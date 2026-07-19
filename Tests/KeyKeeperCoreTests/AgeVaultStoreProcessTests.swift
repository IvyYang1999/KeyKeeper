import Darwin
import Foundation
import XCTest
@testable import KeyKeeperCore

final class AgeVaultStoreProcessTests: XCTestCase {
    func testAgeHelperTimeoutKillsAndReapsProcess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-age-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let processIdentifierURL = directory.appendingPathComponent("helper.pid")
        let helperURL = directory.appendingPathComponent("hanging-age-helper")
        let helper = """
        #!/bin/sh
        printf '%s\n' "$$" > '\(processIdentifierURL.path)'
        exec /bin/sleep 30
        """
        try helper.write(to: helperURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: helperURL.path
        )

        let store = AgeVaultStore(
            directory: directory,
            ageExecutable: helperURL,
            keygenExecutable: helperURL,
            helperProcessTimeout: 0.1
        )

        let startedAt = Date()
        do {
            _ = try store.initVault(passphrase: "timeout-test-placeholder")
            XCTFail("Expected the hanging age helper to time out")
        } catch AgeVaultError.ageExecutableUnavailable {
            throw XCTSkip("execution sandbox does not permit launching the fake age helper")
        } catch AgeVaultError.helperProcessTimedOut {
            // Expected.
        } catch {
            XCTFail("Expected AgeVaultError.helperProcessTimedOut, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        let processIdentifier = try XCTUnwrap(
            pid_t(String(contentsOf: processIdentifierURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        XCTAssertTrue(waitUntilProcessIsGone(processIdentifier))
        XCTAssertEqual(
            AgeVaultError.helperProcessTimedOut.errorDescription,
            "The age helper process timed out"
        )
    }

    private func waitUntilProcessIsGone(_ processIdentifier: pid_t) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            errno = 0
            if kill(processIdentifier, 0) == -1, errno == ESRCH {
                return true
            }
            usleep(10_000)
        } while Date() < deadline
        return false
    }
}
