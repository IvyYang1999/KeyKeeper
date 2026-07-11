import Foundation
import XCTest
@testable import KeyKeeperCore

final class SessionManagerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age") &&
                FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age-keygen"),
            "The system age executables are unavailable."
        )
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testUnlockKeepsSessionForRetrieveWithoutPassphrase() throws {
        try seedVault(value: "opaque-session-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )

        try manager.unlock(passphrase: "session phrase placeholder")

        XCTAssertEqual(
            try manager.retrieve(credentialId: "service-a", fieldName: "access"),
            "opaque-session-value"
        )
        XCTAssertTrue(manager.isUnlocked)
    }

    func testManualLockMakesRetrieveThrowLocked() throws {
        try seedVault(value: "manual-lock-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )
        try manager.unlock(passphrase: "session phrase placeholder")

        manager.lock()

        assertLocked {
            _ = try manager.retrieve(credentialId: "service-a", fieldName: "access")
        }
        XCTAssertEqual(manager.status(), .locked)
    }

    func testExpiredAbsoluteTimeAutomaticallyLocksBeforeOperation() throws {
        try seedVault(value: "expiring-value")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TestClock(start)
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .until(start.addingTimeInterval(60)),
            now: { clock.now }
        )
        try manager.unlock(passphrase: "session phrase placeholder")
        XCTAssertEqual(
            manager.status(),
            .unlocked(expiresAt: start.addingTimeInterval(60))
        )
        clock.advance(by: 61)

        assertLocked {
            _ = try manager.retrieve(credentialId: "service-a", fieldName: "access")
        }
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertEqual(manager.status(), .locked)
    }

    func testLockedSaveAndDeleteThrowLocked() throws {
        try seedVault(value: "locked-operation-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )

        assertLocked {
            try manager.save(
                credentialId: "service-a",
                fieldName: "second",
                value: "unused-placeholder",
                security: .standard
            )
        }
        assertLocked {
            try manager.delete(credentialId: "service-a", fieldName: "access")
        }
    }

    func testManualOrRebootPolicyDoesNotExpireWhenClockAdvances() throws {
        try seedVault(value: "long-session-value")
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot,
            now: { clock.now }
        )
        try manager.unlock(passphrase: "session phrase placeholder")
        clock.advance(by: 60 * 60 * 24 * 365)

        XCTAssertEqual(
            try manager.retrieve(credentialId: "service-a", fieldName: "access"),
            "long-session-value"
        )
        XCTAssertEqual(manager.status(), .unlocked(expiresAt: nil))
    }

    func testWrongPassphraseDoesNotUnlockOrLeakPassphrase() throws {
        try seedVault(value: "protected-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )
        let rejectedPhrase = "rejected phrase placeholder"

        XCTAssertThrowsError(try manager.unlock(passphrase: rejectedPhrase)) { error in
            XCTAssertFalse(String(describing: error).contains(rejectedPhrase))
        }
        XCTAssertFalse(manager.isUnlocked)
        XCTAssertEqual(manager.status(), .locked)
    }

    func testUnlockedSessionCanSaveAndDelete() throws {
        try seedVault(value: "initial-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )
        try manager.unlock(passphrase: "session phrase placeholder")

        try manager.save(
            credentialId: "service-a",
            fieldName: "second",
            value: "saved-through-session",
            security: .standard
        )
        XCTAssertEqual(
            try manager.retrieve(credentialId: "service-a", fieldName: "second"),
            "saved-through-session"
        )
        try manager.delete(credentialId: "service-a", fieldName: "second")
        XCTAssertThrowsError(
            try manager.retrieve(credentialId: "service-a", fieldName: "second")
        ) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("Expected KeychainError.notFound")
            }
        }
    }

    func testConcurrentRetrieveAndLockHaveOnlySuccessOrLockedResults() throws {
        try seedVault(value: "concurrent-session-value")
        let manager = SessionManager(
            directory: directory,
            lockPolicy: .untilManualOrReboot
        )
        try manager.unlock(passphrase: "session phrase placeholder")
        let outcomes = SessionOutcomeCollector()

        DispatchQueue.concurrentPerform(iterations: 40) { index in
            if index == 20 {
                manager.lock()
                return
            }
            do {
                let value = try manager.retrieve(
                    credentialId: "service-a",
                    fieldName: "access"
                )
                outcomes.record(value == "concurrent-session-value" ? .success : .unexpected)
            } catch SessionManagerError.locked {
                outcomes.record(.locked)
            } catch {
                outcomes.record(.unexpected)
            }
        }

        XCTAssertFalse(outcomes.containsUnexpected)
        XCTAssertEqual(manager.status(), .locked)
    }

    private func seedVault(value: String) throws {
        let store = AgeVaultStore(directory: directory)
        _ = try store.initVault(passphrase: "session phrase placeholder")
        try store.save(
            credentialId: "service-a",
            fieldName: "access",
            value: value,
            security: .standard
        )
    }

    private func assertLocked(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case SessionManagerError.locked = error else {
                return XCTFail("Expected SessionManagerError.locked", file: file, line: line)
            }
        }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private enum SessionOutcome {
    case success
    case locked
    case unexpected
}

private final class SessionOutcomeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [SessionOutcome] = []

    var containsUnexpected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcomes.contains { outcome in
            if case .unexpected = outcome { return true }
            return false
        }
    }

    func record(_ outcome: SessionOutcome) {
        lock.lock()
        outcomes.append(outcome)
        lock.unlock()
    }
}
