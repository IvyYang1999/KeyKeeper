import Foundation

public enum SessionLockPolicy: Sendable, Equatable {
    case until(Date)
    case untilManualOrReboot
}

public enum SessionStatus: Sendable, Equatable {
    case locked
    case unlocked(expiresAt: Date?)
}

public enum SessionManagerError: Error, LocalizedError, Sendable {
    case locked

    public var errorDescription: String? {
        switch self {
        case .locked:
            return "The credential session is locked"
        }
    }
}

/// Secret CRUD surface shared by GUI data models and the process-wide session owner.
public protocol CredentialSessionManaging: AnyObject {
    func status() -> SessionStatus
    func retrieve(credentialId: String, fieldName: String) throws -> String
    func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws
    func delete(credentialId: String, fieldName: String) throws
}

/// Owns the only reference to an unlocked `AgeVaultStore` for a process-local session.
public final class SessionManager: @unchecked Sendable {
    private let directory: URL
    private let lockPolicy: SessionLockPolicy
    private let now: @Sendable () -> Date
    private let mutex = NSLock()
    private var unlockedStore: AgeVaultStore?

    public init(
        directory: URL,
        lockPolicy: SessionLockPolicy,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.lockPolicy = lockPolicy
        self.now = now
    }

    public convenience init(
        lockPolicy: SessionLockPolicy = .untilManualOrReboot,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(
            directory: KeyKeeperPaths.applicationSupportDirectory,
            lockPolicy: lockPolicy,
            now: now
        )
    }

    public var isUnlocked: Bool {
        withLock {
            expireIfNeeded()
            return unlockedStore != nil
        }
    }

    public func status() -> SessionStatus {
        withLock {
            expireIfNeeded()
            guard unlockedStore != nil else { return .locked }
            return .unlocked(expiresAt: expirationDate)
        }
    }

    /// Repeated calls are idempotent while the current session remains unlocked.
    public func unlock(passphrase: String) throws {
        try withLock {
            expireIfNeeded()
            guard unlockedStore == nil else { return }

            let store = AgeVaultStore(directory: directory)
            _ = try store.unlock(passphrase: passphrase)

            guard !hasExpired else {
                throw SessionManagerError.locked
            }
            unlockedStore = store
        }
    }

    public func lock() {
        withLock {
            unlockedStore = nil
        }
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        try withUnlockedStore { store in
            try store.retrieve(credentialId: credentialId, fieldName: fieldName)
        }
    }

    public func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws {
        try withUnlockedStore { store in
            try store.save(
                credentialId: credentialId,
                fieldName: fieldName,
                value: value,
                security: security
            )
        }
    }

    public func delete(credentialId: String, fieldName: String) throws {
        try withUnlockedStore { store in
            try store.delete(credentialId: credentialId, fieldName: fieldName)
        }
    }

    private var expirationDate: Date? {
        if case let .until(date) = lockPolicy { return date }
        return nil
    }

    private var hasExpired: Bool {
        guard let expirationDate else { return false }
        return now() >= expirationDate
    }

    private func expireIfNeeded() {
        if hasExpired {
            unlockedStore = nil
        }
    }

    private func withUnlockedStore<T>(_ operation: (AgeVaultStore) throws -> T) throws -> T {
        try withLock {
            expireIfNeeded()
            guard let unlockedStore else { throw SessionManagerError.locked }
            return try operation(unlockedStore)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return try operation()
    }
}

extension SessionManager: CredentialSessionManaging {}
