import Darwin
import Foundation
import XCTest
@testable import KeyKeeperCLI

final class RunCommandProcessTests: XCTestCase {
    func testBusinessProcessUsesDedicatedProcessGroupAndGroupSignal() throws {
        let child = try launchBusinessProcess(command: ["/bin/sleep", "30"])
        defer { child.terminateForParentExit() }

        XCTAssertEqual(getpgid(child.processIdentifier), child.processIdentifier)

        child.forward(signal: SIGTERM)
        XCTAssertEqual(try child.wait(), SIGTERM)
        XCTAssertTrue(waitUntilProcessIsGone(child.processIdentifier))
    }

    func testParentLivenessChannelClosureKillsBusinessProcessGroup() throws {
        let processIdentifierURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-grandchild-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: processIdentifierURL) }
        let child = try launchBusinessProcess(command: [
            "/bin/sh",
            "-c",
            "/bin/sleep 30 & printf '%s\\n' \"$!\" > \"$1\"; wait",
            "keykeeper-guard-test",
            processIdentifierURL.path,
        ])
        defer { child.terminateForParentExit() }
        let grandchildProcessIdentifier = try XCTUnwrap(
            waitForProcessIdentifier(in: processIdentifierURL)
        )

        child.closeParentLivenessChannel()

        XCTAssertEqual(try child.wait(), SIGKILL)
        XCTAssertTrue(waitUntilProcessIsGone(child.processIdentifier))
        XCTAssertTrue(waitUntilProcessIsGone(grandchildProcessIdentifier))
    }

    func testTTYLaunchStopsAfterInstallingParentGuardUntilResumed() throws {
        let child: BusinessProcessHandle
        do {
            child = try BusinessProcessLauncher.launch(
                command: ["/bin/sleep", "30"],
                environment: ProcessInfo.processInfo.environment,
                standardOutput: nil,
                standardError: nil,
                startSuspended: true
            )
        } catch let error as POSIXError where error.code == .EPERM || error.code == .EACCES {
            throw XCTSkip("execution sandbox does not permit launching a process group")
        }
        defer { child.terminateForParentExit() }

        try child.waitUntilSuspended()
        child.resume()
        child.forward(signal: SIGTERM)

        XCTAssertEqual(try child.wait(), SIGTERM)
    }

    private func launchBusinessProcess(command: [String]) throws -> BusinessProcessHandle {
        do {
            return try BusinessProcessLauncher.launch(
                command: command,
                environment: ProcessInfo.processInfo.environment,
                standardOutput: nil,
                standardError: nil
            )
        } catch let error as POSIXError where error.code == .EPERM || error.code == .EACCES {
            throw XCTSkip("execution sandbox does not permit launching a process group")
        }
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

    private func waitForProcessIdentifier(in url: URL) -> pid_t? {
        let deadline = Date().addingTimeInterval(1)
        repeat {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let processIdentifier = pid_t(
                   contents.trimmingCharacters(in: .whitespacesAndNewlines)
               ) {
                return processIdentifier
            }
            usleep(10_000)
        } while Date() < deadline
        return nil
    }
}
