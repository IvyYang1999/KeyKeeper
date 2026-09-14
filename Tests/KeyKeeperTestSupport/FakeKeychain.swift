import Foundation
import Security
import KeyKeeperCore

/// A simulated login Keychain for tests, behaving the way `SecItemBlobIO` does against the real one.
///
/// 【曾经的 bug · 2026-09-13】every test file had its own in-memory fake, and most of them stored
/// whatever they were given. The real Keychain does not: "replace" only updates an item that
/// exists, "create" only adds one that does not. The integrity key was written with "replace"
/// while no key existed, so in production it was never created — every signed approvals save
/// failed and meta.json was never signed. All twenty fakes were green. One fake, one set of
/// rules, and the rules are the real ones.
///
/// One `FakeKeychain` holds many items, addressed by service name, so a test can hand the same
/// simulated Keychain to the credential store, the integrity keys and the browser-session store,
/// exactly as the app does with the real one.
public final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var reads: [String: Int] = [:]
    private var ordinaryReads: [String: Int] = [:]
    private var writes: [String: Int] = [:]
    private var pendingReadFailures: [String: Int] = [:]
    /// Items whose ACL does not trust this build: a non-interactive read is refused, an interactive
    /// one counts as the person clicking Allow.
    private var interactionRequired: Set<String> = []
    /// Items the person clicked Deny on.
    private var denied: Set<String> = []

    public init() {}

    public func io(_ service: String) -> FakeKeychainIO { FakeKeychainIO(keychain: self, service: service) }

    public subscript(service: String) -> Data? {
        get { lock.withLock { items[service] } }
        set { lock.withLock { items[service] = newValue } }
    }

    public func services() -> [String] { lock.withLock { items.keys.sorted() } }

    /// Fail the next `count` reads of this item as the Keychain would when it cannot be opened.
    public func failNextReads(of service: String, count: Int) {
        lock.withLock { pendingReadFailures[service] = count }
    }

    public func requireInteraction(for service: String, _ required: Bool = true) {
        lock.withLock { if required { interactionRequired.insert(service) } else { interactionRequired.remove(service) } }
    }

    public func deny(_ service: String, _ deny: Bool = true) {
        lock.withLock { if deny { denied.insert(service) } else { denied.remove(service) } }
    }

    public func readCount(_ service: String) -> Int { lock.withLock { reads[service] ?? 0 } }
    public func ordinaryReadCount(_ service: String) -> Int { lock.withLock { ordinaryReads[service] ?? 0 } }
    public func writeCount(_ service: String) -> Int { lock.withLock { writes[service] ?? 0 } }

    func read(_ service: String, interactive: Bool) throws -> Data? {
        try lock.withLock {
            if interactive { ordinaryReads[service, default: 0] += 1 } else { reads[service, default: 0] += 1 }
            if let left = pendingReadFailures[service], left > 0 {
                pendingReadFailures[service] = left - 1
                throw KeychainError.retrieveFailed(errSecAuthFailed)
            }
            if interactionRequired.contains(service) {
                if !interactive { throw KeychainError.retrieveFailed(errSecInteractionNotAllowed) }
                if denied.contains(service) { throw KeychainError.retrieveFailed(errSecAuthFailed) }
            }
            return items[service]
        }
    }

    func write(_ service: String, _ data: Data, replacingExisting: Bool) throws {
        try lock.withLock {
            if replacingExisting {
                // SecItemUpdate: the item has to be there.
                guard items[service] != nil else { throw CredentialStorageError.missingStore }
            } else {
                // SecItemAdd: it must not be.
                guard items[service] == nil else { throw KeychainError.saveFailed(errSecDuplicateItem) }
            }
            items[service] = data
            writes[service, default: 0] += 1
        }
    }
}

/// One item of a `FakeKeychain`, as the stores see it. The knobs are the ones tests reach for.
public final class FakeKeychainIO: KeychainBlobIO, @unchecked Sendable {
    public let keychain: FakeKeychain
    public let service: String

    /// Thrown by every read, before anything else.
    public var readError: Error?
    /// Thrown by every write, before anything else.
    public var writeError: Error?
    public var failReads: Bool {
        get { readError != nil }
        set { readError = newValue ? KeychainError.unexpectedData : nil }
    }
    public var failWrites: Bool {
        get { writeError != nil }
        set { writeError = newValue ? CocoaError(.fileWriteNoPermission) : nil }
    }
    /// Runs after the write checks and before the data is stored — the seam for read/write races.
    public var beforeWrite: (() -> Void)?
    /// Runs after a successful store; throwing from here simulates a failure reported after the bytes landed.
    public var afterWrite: (() throws -> Void)?
    public var onWrite: (() throws -> Void)? {
        get { afterWrite }
        set { afterWrite = newValue }
    }
    public var onRead: (() -> Void)?

    public init(keychain: FakeKeychain = FakeKeychain(), service: String = "com.keykeeper.test.fake") {
        self.keychain = keychain
        self.service = service
    }

    public convenience init(blob: Data?) {
        self.init()
        self.blob = blob
    }

    /// The stored bytes, or nil when no item exists. Setting nil deletes the item.
    public var blob: Data? {
        get { keychain[service] }
        set { keychain[service] = newValue }
    }
    public var writes: Int { keychain.writeCount(service) }
    public var writeCount: Int { writes }
    /// Non-interactive reads (the inventory path).
    public var reads: Int { keychain.readCount(service) }
    /// Interactive reads (everything else).
    public var ordinaryReads: Int { keychain.ordinaryReadCount(service) }

    /// `onRead` runs once the read has been counted, so a hook can key off `reads`.
    public func readBlob() throws -> Data? {
        if let readError { throw readError }
        let data = try keychain.read(service, interactive: true)
        onRead?()
        return data
    }

    public func readBlobWithoutInteraction() throws -> Data? {
        if let readError { throw readError }
        let data = try keychain.read(service, interactive: false)
        onRead?()
        return data
    }

    public func writeBlob(_ data: Data, replacingExisting: Bool) throws {
        if let writeError { throw writeError }
        beforeWrite?()
        try keychain.write(service, data, replacingExisting: replacingExisting)
        try afterWrite?()
    }
}
