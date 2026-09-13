import CryptoKit
import Foundation

/// Proof that an approvals file is the one KeyKeeper wrote.
///
/// 【独立审计 2026-09-13】grants.json and service-grants.json are ordinary files, writable by the
/// user — and so by any process running as the user. One appended line (an "Always" for its own
/// fingerprint, or `"mode": "permissive"`) and it could read strict credentials with no prompt at
/// all. Same defence as meta.json: an HMAC keyed from the Keychain, written on every save, checked
/// on every read, and a file that fails the check holds no approvals.
///
/// Its own key, not meta.json's: that key's existence already means "this machine signs its
/// metadata" and may exist today; reusing it would declare every existing approvals file tampered
/// the first time the new build launched.
///
/// Only the app holds it. The CLI cannot read the key without a Keychain prompt, so its reads stay
/// advisory (the app decides every real access) and it refuses to rewrite a file the app signed.
public final class GrantFileIntegrity: @unchecked Sendable {
    /// One key per file, never shared. 【独立审计第二轮 · critical，2026-09-13 23 点在 yyt 本机真实发生】
    /// both approvals files used to share one key. On the first launch after upgrading, pruning
    /// grants.json created it; pruning service-grants.json a moment later found a key and an
    /// unsigned file, judged it tampered, and replaced it with an empty one — every background
    /// approval and the access log gone, and the mode switched to "ask me first".
    public static let grantsKeyName = "grants-mac"
    public static let serviceGrantsKeyName = "service-grants-mac"

    /// Set once by the app, before it serves anything. Stores read these at use time rather than
    /// capturing them at init, because the app builds some of its stores before launch finishes.
    nonisolated(unsafe) public static var grantsDefault: GrantFileIntegrity?
    nonisolated(unsafe) public static var serviceGrantsDefault: GrantFileIntegrity?

    /// The app's wiring, in one place, so tests run exactly what ships.
    public static func configureAppDefaults(makeIO: (String) -> KeychainBlobIO) {
        let grantsIO = makeIO(IntegrityKeyNames.service(grantsKeyName))
        grantsDefault = GrantFileIntegrity(io: grantsIO)
        // Development builds of 0.3.4 signed service-grants.json with the grants key; adopt what
        // that key vouches for, and sign it with its own key on the next write.
        serviceGrantsDefault = GrantFileIntegrity(io: makeIO(IntegrityKeyNames.service(serviceGrantsKeyName)),
                                                  legacyIO: grantsIO)
    }

    public enum Verdict: Equatable, Sendable { case intact, unsigned, tampered, unavailable }

    private let io: KeychainBlobIO
    private let legacyIO: KeychainBlobIO?
    private let lock = NSLock()
    private var cachedKey: Data?

    public init(io: KeychainBlobIO, legacyIO: KeychainBlobIO? = nil) {
        self.io = io
        self.legacyIO = legacyIO
    }

    /// `file` must already have its own `integrity` cleared; `recorded` is what the file carried.
    func verdict<T: Encodable>(for file: T, recorded: String?) -> Verdict {
        let key: Data?
        do { key = try existingKey() } catch {
            // Could not read the Keychain (denied, locked). That says nothing about the file, and
            // treating it as tampering used to wipe every approval on the next write.
            return .unavailable
        }
        guard let key else {
            guard let recorded else { return .unsigned }   // from before signing existed
            if let legacyIO, let legacy = try? MetaIntegrityKey.existing(io: legacyIO),
               Self.matches(file, recorded: recorded, key: legacy) {
                return .unsigned
            }
            // Carries a MAC no key of ours can vouch for.
            return .tampered
        }
        // A key exists, so this file is signed: a missing MAC means someone removed it.
        guard let recorded else { return .tampered }
        return Self.matches(file, recorded: recorded, key: key) ? .intact : .tampered
    }

    private static func matches<T: Encodable>(_ file: T, recorded: String, key: Data) -> Bool {
        guard let expected = try? mac(for: file, key: key) else { return false }
        let a = Array(recorded.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }   // constant time
        return difference == 0
    }

    func sign<T: Encodable>(_ file: T) throws -> String {
        try Self.mac(for: file, key: try loadOrCreateKey())
    }

    static func mac<T: Encodable>(for file: T, key: Data) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601   // the stores' own encoding, so a reload re-encodes identically
        let data = try encoder.encode(file)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))).base64EncodedString()
    }

    private func existingKey() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        cachedKey = try MetaIntegrityKey.existing(io: io)
        return cachedKey
    }

    private func loadOrCreateKey() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        let key = try MetaIntegrityKey.loadOrCreate(io: io)
        cachedKey = key
        return key
    }
}

public enum GrantFileIntegrityError: Error, LocalizedError {
    case managedByApp
    case keyUnavailable

    public var errorDescription: String? {
        switch self {
        case .managedByApp:
            return "KeyKeeper signs its approvals file, so only the KeyKeeper app can change it. Nothing was changed."
        case .keyUnavailable:
            return "KeyKeeper could not read the key that protects its approvals file from the Keychain, so it did not touch the file. Try again once the Keychain is unlocked."
        }
    }
}

/// Integrity keys follow the credential store's Keychain namespace, so an isolated instance
/// (KEYKEEPER_KEYCHAIN_SERVICE=com.keykeeper.test.…) never creates or reads the production keys.
/// 【独立审计第二轮】they used to be fixed names: one isolated run on this Mac made the production
/// app judge its own unsigned files tampered.
public enum IntegrityKeyNames {
    public static func service(_ name: String,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let test = environment["KEYKEEPER_KEYCHAIN_SERVICE"], test.hasPrefix("com.keykeeper.test."),
           environment["KEYKEEPER_DATA_DIR"]?.isEmpty == false {
            return test + "." + name
        }
        return "com.keykeeper." + name
    }
}
