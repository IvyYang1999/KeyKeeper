import Combine
import Foundation
import KeyKeeperCore

extension Notification.Name {
    /// Posted on the main thread whenever the vault session is unlocked or locked,
    /// by the GUI or by a CLI request that reached the IPC server.
    static let keyKeeperSessionDidChange = Notification.Name("com.keykeeper.session.didChange")
}

/// Session lifecycle surface the GUI needs on top of secret CRUD.
protocol SessionLockControlling: AnyObject {
    var isVaultInitialized: Bool { get }
    func status() -> SessionStatus
    func unlock(passphrase: String) throws
    func lock()
    func createVault(passphrase: String) throws -> EmergencyIdentity
}

extension SessionManager: SessionLockControlling {}

/// What the session banner (and the menu bar icon) should show.
enum SessionBannerState: Equatable {
    /// No vault on disk yet: the user has to choose a passphrase first.
    case needsVault
    case locked
    case unlocked(expiresAt: Date?)

    static func derive(status: SessionStatus, vaultInitialized: Bool) -> SessionBannerState {
        switch status {
        case .unlocked(let expiresAt):
            return .unlocked(expiresAt: expiresAt)
        case .locked:
            return vaultInitialized ? .locked : .needsVault
        }
    }

    var isUnlocked: Bool {
        if case .unlocked = self { return true }
        return false
    }
}

@MainActor
final class SessionStateViewModel: ObservableObject {
    @Published private(set) var bannerState: SessionBannerState
    @Published var passphrase = ""
    @Published var confirmPassphrase = ""
    @Published private(set) var errorMessage: String?
    /// The emergency recovery identity, shown exactly once after the vault is created.
    @Published private(set) var recoveryIdentity: String?
    @Published private(set) var isBusy = false

    private let session: SessionLockControlling
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(session: SessionLockControlling, autoRefresh: Bool = true) {
        self.session = session
        bannerState = SessionBannerState.derive(
            status: session.status(),
            vaultInitialized: session.isVaultInitialized
        )

        guard autoRefresh else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .keyKeeperSessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Timed sessions expire on their own and reboots lock silently; poll cheaply.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        timer?.invalidate()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    var isUnlocked: Bool { bannerState.isUnlocked }

    func refresh() {
        let next = SessionBannerState.derive(
            status: session.status(),
            vaultInitialized: session.isVaultInitialized
        )
        if next != bannerState {
            bannerState = next
        }
    }

    func unlock() {
        let phrase = passphrase
        passphrase = ""
        guard !phrase.isEmpty else {
            errorMessage = "Enter your passphrase."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try session.unlock(passphrase: phrase)
            errorMessage = nil
            refresh()
            NotificationCenter.default.post(name: .keyKeeperSessionDidChange, object: nil)
        } catch {
            errorMessage = Self.unlockErrorMessage(for: error)
            refresh()
        }
    }

    func lock() {
        session.lock()
        errorMessage = nil
        refresh()
        NotificationCenter.default.post(name: .keyKeeperSessionDidChange, object: nil)
    }

    func createVault() {
        let phrase = passphrase
        let confirmation = confirmPassphrase
        if let problem = Self.validateNewPassphrase(phrase, confirm: confirmation) {
            errorMessage = problem
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let emergency = try session.createVault(passphrase: phrase)
            passphrase = ""
            confirmPassphrase = ""
            errorMessage = nil
            recoveryIdentity = emergency.identity
            refresh()
            NotificationCenter.default.post(name: .keyKeeperSessionDidChange, object: nil)
        } catch {
            errorMessage = Self.unlockErrorMessage(for: error)
        }
    }

    func dismissRecoveryIdentity() {
        recoveryIdentity = nil
    }

    /// Returns a user-facing problem, or nil when the new passphrase is acceptable.
    static func validateNewPassphrase(_ passphrase: String, confirm: String) -> String? {
        if passphrase.isEmpty { return "Choose a passphrase." }
        if passphrase.count < 8 { return "Use at least 8 characters." }
        if passphrase != confirm { return "The two passphrases don't match." }
        return nil
    }

    static func unlockErrorMessage(for error: Error) -> String {
        switch error {
        case AgeVaultError.identityDecryptionFailed:
            return "Wrong passphrase."
        case AgeVaultError.ageExecutableUnavailable:
            return "The age tool is missing. Install it with: brew install age"
        case AgeVaultError.notInitialized:
            return "No vault yet. Create one first."
        case AgeVaultError.alreadyInitialized:
            return "A vault already exists. Unlock it instead."
        default:
            return error.localizedDescription
        }
    }
}
