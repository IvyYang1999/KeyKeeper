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
    public static let service = "com.keykeeper.grants-mac"

    /// Set once by the app, before it serves anything. Stores read it at use time rather than
    /// capturing it at init, because the app builds some of its stores before launch finishes.
    nonisolated(unsafe) public static var processDefault: GrantFileIntegrity?

    public enum Verdict: Equatable, Sendable { case intact, unsigned, tampered }

    private let io: KeychainBlobIO
    private let lock = NSLock()
    private var cachedKey: Data?

    public init(io: KeychainBlobIO) { self.io = io }

    /// `file` must already have its own `integrity` cleared; `recorded` is what the file carried.
    func verdict<T: Encodable>(for file: T, recorded: String?) -> Verdict {
        guard let key = existingKey() else {
            // No key here yet: a file from before signing existed. A file that carries a MAC while
            // no key can be read is not one this app can vouch for.
            return recorded == nil ? .unsigned : .tampered
        }
        // A key exists, so this machine signs its approvals: a missing MAC means someone removed it.
        guard let recorded, let expected = try? Self.mac(for: file, key: key) else { return .tampered }
        let a = Array(recorded.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return .tampered }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }   // constant time
        return difference == 0 ? .intact : .tampered
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

    private func existingKey() -> Data? {
        lock.lock(); defer { lock.unlock() }
        if let cachedKey { return cachedKey }
        cachedKey = try? MetaIntegrityKey.existing(io: io)
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

    public var errorDescription: String? {
        "KeyKeeper signs its approvals file, so only the KeyKeeper app can change it. Nothing was changed."
    }
}
