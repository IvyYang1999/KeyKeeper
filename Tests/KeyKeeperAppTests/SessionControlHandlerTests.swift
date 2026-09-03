import Foundation
import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class SessionControlHandlerTests: XCTestCase {
    func testUnlockSuccessAndRepeatedUnlockAreIdempotent() {
        let session = FakeSessionController()
        let server = IPCServer(session: session)
        let request = SessionControlRequest(
            action: .unlock,
            passphrase: "test phrase placeholder"
        )

        let first = server.handleSessionControl(request)
        let second = server.handleSessionControl(request)

        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)
        XCTAssertEqual(first.state, .unlockedManual)
        XCTAssertEqual(second.state, .unlockedManual)
        XCTAssertEqual(session.acceptedUnlockCount, 1)
    }

    func testWrongPassphraseResponseDoesNotLeakPhrase() {
        let rejectedPhrase = "rejected phrase placeholder"
        let session = FakeSessionController()
        session.rejectedPassphrase = rejectedPhrase
        let server = IPCServer(session: session)

        let response = server.handleSessionControl(SessionControlRequest(
            action: .unlock,
            passphrase: rejectedPhrase
        ))

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.errorCode, .unlockFailed)
        XCTAssertFalse(response.error?.contains(rejectedPhrase) ?? false)
    }

    func testLockIsIdempotent() {
        let session = FakeSessionController()
        let server = IPCServer(session: session)

        let first = server.handleSessionControl(SessionControlRequest(action: .lock))
        let second = server.handleSessionControl(SessionControlRequest(action: .lock))

        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)
        XCTAssertEqual(first.state, .locked)
        XCTAssertEqual(second.state, .locked)
        XCTAssertEqual(session.lockCount, 2)
    }

    func testStatusReportsLockedManualAndTimedStates() {
        let session = FakeSessionController()
        let server = IPCServer(session: session)

        session.currentStatus = .locked
        XCTAssertEqual(
            server.handleSessionControl(SessionControlRequest(action: .status)).state,
            .locked
        )

        session.currentStatus = .unlocked(expiresAt: nil)
        XCTAssertEqual(
            server.handleSessionControl(SessionControlRequest(action: .status)).state,
            .unlockedManual
        )

        let expiration = Date(timeIntervalSince1970: 1_800_000_000)
        session.currentStatus = .unlocked(expiresAt: expiration)
        let timed = server.handleSessionControl(SessionControlRequest(action: .status))
        XCTAssertEqual(timed.state, .unlockedUntil)
        XCTAssertEqual(timed.expiresAt, expiration)
    }

    func testInvalidSessionPayloadIsRejectedWithoutChangingSession() {
        let session = FakeSessionController()
        let server = IPCServer(session: session)

        let missingPhrase = server.handleSessionControl(SessionControlRequest(action: .unlock))
        let phraseOnStatus = server.handleSessionControl(SessionControlRequest(
            action: .status,
            passphrase: "test phrase placeholder"
        ))

        XCTAssertEqual(missingPhrase.errorCode, .invalidRequest)
        XCTAssertEqual(phraseOnStatus.errorCode, .invalidRequest)
        XCTAssertEqual(session.acceptedUnlockCount, 0)
        XCTAssertEqual(session.lockCount, 0)
    }
}

private final class FakeSessionController: SessionControlling, @unchecked Sendable {
    var isVaultInitialized = true
    var currentStatus: SessionStatus = .locked
    var rejectedPassphrase: String?
    private(set) var acceptedUnlockCount = 0
    private(set) var lockCount = 0

    func status() -> SessionStatus {
        currentStatus
    }

    func unlock(passphrase: String) throws {
        if passphrase == rejectedPassphrase {
            throw FakeSessionError.rejected(passphrase)
        }
        guard case .locked = currentStatus else { return }
        acceptedUnlockCount += 1
        currentStatus = .unlocked(expiresAt: nil)
    }

    func lock() {
        lockCount += 1
        currentStatus = .locked
    }

    func retrieve(credentialId: String, fieldName: String) throws -> String {
        throw FakeSessionError.unexpectedRetrieve
    }
}

private enum FakeSessionError: Error, LocalizedError {
    case rejected(String)
    case unexpectedRetrieve

    var errorDescription: String? {
        switch self {
        case .rejected(let phrase):
            return "Rejected \(phrase)"
        case .unexpectedRetrieve:
            return "Unexpected value retrieval"
        }
    }
}

extension SessionControlHandlerTests {
    func test没有vault时unlock失败提示去App建库() {
        let session = FakeSessionController()
        session.isVaultInitialized = false
        session.rejectedPassphrase = "any phrase placeholder"
        let server = IPCServer(session: session)

        let response = server.handleSessionControl(SessionControlRequest(
            action: .unlock, passphrase: "any phrase placeholder"
        ))

        XCTAssertFalse(response.success)
        XCTAssertEqual(response.errorCode, .unlockFailed)
        XCTAssertTrue(response.error?.contains("No vault yet") ?? false)
        XCTAssertFalse(response.error?.contains("any phrase") ?? true)
        XCTAssertTrue(IPCServer.unlockFailureMessage(vaultInitialized: true).contains("Wrong passphrase"))
    }
}
