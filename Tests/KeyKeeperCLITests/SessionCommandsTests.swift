import ArgumentParser
import Foundation
import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

final class SessionCommandsTests: XCTestCase {
    func testUnlockParserRejectsPassphraseInArgv() {
        XCTAssertThrowsError(try KeyKeeperCommand.parseAsRoot([
            "unlock",
            "--passphrase",
            "argv phrase placeholder",
        ]))
    }

    func testUnlockParserRejectsPositionalPassphraseInArgv() {
        XCTAssertThrowsError(try KeyKeeperCommand.parseAsRoot([
            "unlock",
            "argv phrase placeholder",
        ]))
    }

    func testTerminalReaderUsesInjectedHiddenPromptOnlyForTTY() throws {
        var hiddenPromptCount = 0
        let reader = TerminalPassphraseReader(
            isStandardInputTerminal: { true },
            readHiddenPassphrase: {
                hiddenPromptCount += 1
                return "tty phrase placeholder"
            }
        )

        XCTAssertEqual(try reader.readPassphrase(), "tty phrase placeholder")
        XCTAssertEqual(hiddenPromptCount, 1)
    }

    func testTerminalReaderRejectsPipeBeforeReading() {
        var hiddenPromptCount = 0
        let reader = TerminalPassphraseReader(
            isStandardInputTerminal: { false },
            readHiddenPassphrase: {
                hiddenPromptCount += 1
                return "pipe phrase placeholder"
            }
        )

        XCTAssertThrowsError(try reader.readPassphrase()) { error in
            XCTAssertTrue(error.localizedDescription.contains("interactive terminal"))
        }
        XCTAssertEqual(hiddenPromptCount, 0)
    }

    func testUnlockUsesPromptAndIsOnlyCommandAllowedToLaunchApp() throws {
        var requests: [(SessionControlRequest, Bool)] = []
        let executor = SessionCommandExecutor { request, launchIfNeeded in
            requests.append((request, launchIfNeeded))
            return SessionControlResponse(success: true, state: .unlockedManual)
        }
        let reader = StubPassphraseReader(value: "tty phrase placeholder")

        let output = try executor.unlock(using: reader)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].0.action, .unlock)
        XCTAssertEqual(requests[0].0.passphrase, "tty phrase placeholder")
        XCTAssertTrue(requests[0].1)
        XCTAssertEqual(
            output,
            "unlocked (until you lock manually or the KeyKeeper app quits/restarts)"
        )
    }

    func testLockAndStatusDoNotLaunchApp() throws {
        var launchFlags: [Bool] = []
        let executor = SessionCommandExecutor { request, launchIfNeeded in
            launchFlags.append(launchIfNeeded)
            let state: SessionControlState = request.action == .lock ? .locked : .unlockedManual
            return SessionControlResponse(success: true, state: state)
        }

        XCTAssertEqual(try executor.lock(), "locked")
        XCTAssertEqual(
            try executor.status(),
            "unlocked (until you lock manually or the KeyKeeper app quits/restarts)"
        )
        XCTAssertEqual(launchFlags, [false, false])
    }

    func testLockAndStatusTreatAppNotRunningAsLocked() throws {
        let executor = SessionCommandExecutor { _, _ in
            throw IPCError.appNotRunning
        }

        XCTAssertEqual(try executor.lock(), "locked")
        XCTAssertEqual(try executor.status(), "locked (app not running)")
    }

    func testOldAppInvalidRequestBecomesUpgradeError() {
        let oldAppResponse = IPCResponse.value(ValueResponse(
            success: false,
            error: "Invalid request",
            errorCode: .invalidRequest
        ))

        XCTAssertThrowsError(try IPCClient.decodeSessionControlResponse(oldAppResponse)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The installed KeyKeeper app is too old for this command. Update the app, then retry."
            )
        }
    }

    func testEnvironmentCannotBypassNonTTYRequirementAndPhraseDoesNotLeak() throws {
        let executable = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("keykeeper")
        let phrase = "environment phrase placeholder"
        let output = Pipe()
        let input = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["unlock"]
        var environment = ProcessInfo.processInfo.environment
        environment["KEYKEEPER_PASSPHRASE"] = phrase
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        try process.run()
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("interactive terminal"), text)
        XCTAssertFalse(text.contains(phrase), text)
    }

    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct StubPassphraseReader: PassphraseReading {
    let value: String

    func readPassphrase() throws -> String {
        value
    }
}
