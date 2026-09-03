import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore

@MainActor
final class SessionStateViewModelTests: XCTestCase {
    func test没有vault时显示创建状态() {
        let session = FakeLockSession(initialized: false, status: .locked)
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        XCTAssertEqual(vm.bannerState, .needsVault)
        XCTAssertFalse(vm.isUnlocked)
    }

    func test锁定时正确口令解锁并清空输入() {
        let session = FakeLockSession(initialized: true, status: .locked)
        session.acceptedPassphrase = "correct horse battery"
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        XCTAssertEqual(vm.bannerState, .locked)

        vm.passphrase = "correct horse battery"
        vm.unlock()

        XCTAssertEqual(vm.bannerState, .unlocked(expiresAt: nil))
        XCTAssertTrue(vm.isUnlocked)
        XCTAssertEqual(vm.passphrase, "")
        XCTAssertNil(vm.errorMessage)
    }

    func test错误口令保持锁定且提示不含口令() {
        let session = FakeLockSession(initialized: true, status: .locked)
        session.acceptedPassphrase = "right"
        let vm = SessionStateViewModel(session: session, autoRefresh: false)

        vm.passphrase = "wrong phrase"
        vm.unlock()

        XCTAssertEqual(vm.bannerState, .locked)
        XCTAssertEqual(vm.errorMessage, "Wrong passphrase.")
        XCTAssertFalse(vm.errorMessage?.contains("wrong phrase") ?? true)
        XCTAssertEqual(vm.passphrase, "")
    }

    func test空口令不调用解锁() {
        let session = FakeLockSession(initialized: true, status: .locked)
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        vm.unlock()
        XCTAssertEqual(session.unlockAttempts, 0)
        XCTAssertNotNil(vm.errorMessage)
    }

    func test上锁后状态回到锁定() {
        let session = FakeLockSession(initialized: true, status: .unlocked(expiresAt: nil))
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        XCTAssertTrue(vm.isUnlocked)
        vm.lock()
        XCTAssertEqual(vm.bannerState, .locked)
        XCTAssertEqual(session.lockCount, 1)
    }

    func test创建vault口令校验() {
        XCTAssertNotNil(SessionStateViewModel.validateNewPassphrase("", confirm: ""))
        XCTAssertNotNil(SessionStateViewModel.validateNewPassphrase("short", confirm: "short"))
        XCTAssertNotNil(SessionStateViewModel.validateNewPassphrase("long enough", confirm: "different"))
        XCTAssertNil(SessionStateViewModel.validateNewPassphrase("long enough", confirm: "long enough"))
    }

    func test创建vault后解锁并展示一次性恢复密钥() {
        let session = FakeLockSession(initialized: false, status: .locked)
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        vm.passphrase = "a brand new phrase"
        vm.confirmPassphrase = "a brand new phrase"

        vm.createVault()

        XCTAssertEqual(session.createdWith, "a brand new phrase")
        XCTAssertEqual(vm.bannerState, .unlocked(expiresAt: nil))
        XCTAssertEqual(vm.recoveryIdentity, "AGE-SECRET-KEY-RECOVERY")
        XCTAssertEqual(vm.passphrase, "")
        XCTAssertEqual(vm.confirmPassphrase, "")

        vm.dismissRecoveryIdentity()
        XCTAssertNil(vm.recoveryIdentity)
    }

    func test口令不匹配时不创建vault() {
        let session = FakeLockSession(initialized: false, status: .locked)
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        vm.passphrase = "a brand new phrase"
        vm.confirmPassphrase = "another phrase"
        vm.createVault()
        XCTAssertNil(session.createdWith)
        XCTAssertEqual(vm.bannerState, .needsVault)
        XCTAssertNotNil(vm.errorMessage)
    }

    func test外部会话变更通知后刷新状态() {
        let session = FakeLockSession(initialized: true, status: .locked)
        let vm = SessionStateViewModel(session: session, autoRefresh: false)
        session.currentStatus = .unlocked(expiresAt: nil)
        vm.refresh()
        XCTAssertTrue(vm.isUnlocked)
    }

    func test解锁行文案区分定时与手动() {
        XCTAssertEqual(
            SessionBanner.unlockedLabel(expiresAt: nil),
            "Unlocked until you lock or quit"
        )
        let now = Date()
        let label = SessionBanner.unlockedLabel(expiresAt: now.addingTimeInterval(3600), now: now)
        XCTAssertTrue(label.hasPrefix("Unlocked, locks"))
    }
}

private final class FakeLockSession: SessionLockControlling {
    var isVaultInitialized: Bool
    var currentStatus: SessionStatus
    var acceptedPassphrase: String?
    var unlockAttempts = 0
    var lockCount = 0
    var createdWith: String?

    init(initialized: Bool, status: SessionStatus) {
        isVaultInitialized = initialized
        currentStatus = status
    }

    func status() -> SessionStatus { currentStatus }

    func unlock(passphrase: String) throws {
        unlockAttempts += 1
        guard passphrase == acceptedPassphrase else {
            throw AgeVaultError.identityDecryptionFailed
        }
        currentStatus = .unlocked(expiresAt: nil)
    }

    func lock() {
        lockCount += 1
        currentStatus = .locked
    }

    func createVault(passphrase: String) throws -> EmergencyIdentity {
        createdWith = passphrase
        isVaultInitialized = true
        currentStatus = .unlocked(expiresAt: nil)
        return EmergencyIdentity(
            identity: "AGE-SECRET-KEY-RECOVERY",
            recipient: "age1recovery",
            mainRecipient: "age1main"
        )
    }
}
