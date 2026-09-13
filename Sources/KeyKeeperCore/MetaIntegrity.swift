import CryptoKit
import Foundation

/// Proof that meta.json is the one KeyKeeper wrote.
///
/// 【安全审计 2026-09-13】meta.json is plaintext, and it decides which fields are secret, what
/// protection each credential has, and holds the values of plain fields outright. A process
/// running as this user could flip `secret: true` to false, put its own value in, and
/// `keykeeper get` would hand that to an agent — no Keychain read, no approval, no audit entry,
/// and nothing in the product could tell. The Keychain protects the secrets; nothing protected
/// the file that says what to do with them.
///
/// So: an HMAC over the file, keyed from the Keychain, written on every save and checked on
/// every load.
public enum MetaIntegrity {
    public enum Verdict: Equatable, Sendable {
        case intact
        /// No MAC recorded — written before this existed, or by an older build.
        case unsigned
        case tampered
    }

    public static func mac(for meta: MetaFile, key: Data) throws -> String {
        var subject = meta
        subject.integrity = nil          // the MAC never covers itself
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]   // canonical: key order must not matter
        let data = try encoder.encode(subject)
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(code).base64EncodedString()
    }

    public static func verify(_ meta: MetaFile, key: Data) -> Verdict {
        guard let recorded = meta.integrity, !recorded.isEmpty else { return .unsigned }
        guard let expected = try? mac(for: meta, key: key) else { return .tampered }
        // Constant-time: a timing side channel here would leak the MAC one byte at a time.
        let a = Array(recorded.utf8), b = Array(expected.utf8)
        guard a.count == b.count else { return .tampered }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0 ? .intact : .tampered
    }
}

/// The HMAC key, kept where the secrets are.
///
/// Its existence is also the marker for "this machine signs its metadata". That matters: without
/// it, stripping the `integrity` line would look exactly like an old file and sail through, and
/// a defence anyone can delete is not a defence. The key lives in the Keychain, where the
/// attacker in this threat model cannot reach it.
public enum MetaIntegrityKey {
    public static var service: String { IntegrityKeyNames.service("metadata-mac") }
    static let length = 32

    public static func existing(io: KeychainBlobIO) throws -> Data? {
        guard let data = try io.readBlob(), data.count == length else { return nil }
        return data
    }

    public static func loadOrCreate(io: KeychainBlobIO) throws -> Data {
        if let existing = try existing(io: io) { return existing }
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, length, $0.baseAddress!) }
        guard status == errSecSuccess else { throw KeychainError.unexpectedData }
        do {
            // Create-only. 【独立审计 2026-09-13 · critical】this said replacingExisting: true, which for
            // the real Keychain means update-only: with no key yet it threw, so the key was never
            // created — every signed approvals save failed and meta.json was never signed. The test
            // doubles ignored the flag, which is why nothing went red.
            try io.writeBlob(bytes, replacingExisting: false)
        } catch {
            // Someone else created it between our read and our write: theirs is the key.
            if let created = try existing(io: io) { return created }
            throw error
        }
        return bytes
    }
}
