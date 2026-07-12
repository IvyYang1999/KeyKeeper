import CommonCrypto
import CryptoKit
import Foundation
import Security

enum IdentityCipher {
    private static let magic = Data("KEYKID01".utf8)
    private static let iterationCount: UInt32 = 600_000
    private static let saltByteCount = 16
    private static let nonceByteCount = 12
    private static let keyByteCount = 32
    private static let tagByteCount = 16

    /// PBKDF2-HMAC-SHA256 at 600,000 iterations follows OWASP's password-storage
    /// work-factor guidance. A random 128-bit salt prevents precomputation, while
    /// AES-256-GCM provides authenticated encryption with a fresh 96-bit nonce.
    static func seal(_ plaintext: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw IdentityCipherError.emptyPassphrase }
        let salt = try randomData(count: saltByteCount)
        let nonceData = try randomData(count: nonceByteCount)
        let header = magic + encode(iterationCount) + salt + nonceData
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        return header + box.ciphertext + box.tag
    }

    static func open(_ container: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else { throw IdentityCipherError.emptyPassphrase }
        let headerByteCount = magic.count + MemoryLayout<UInt32>.size
            + saltByteCount + nonceByteCount
        guard container.count >= headerByteCount + tagByteCount else {
            throw IdentityCipherError.invalidContainer
        }

        var cursor = 0
        let storedMagic = take(magic.count, from: container, cursor: &cursor)
        guard storedMagic == magic else { throw IdentityCipherError.invalidContainer }
        let iterations = decodeUInt32(take(MemoryLayout<UInt32>.size, from: container, cursor: &cursor))
        guard iterations == iterationCount else { throw IdentityCipherError.invalidContainer }
        let salt = take(saltByteCount, from: container, cursor: &cursor)
        let nonceData = take(nonceByteCount, from: container, cursor: &cursor)
        let header = container.prefix(headerByteCount)
        let ciphertext = container[cursor..<(container.count - tagByteCount)]
        let tag = container.suffix(tagByteCount)

        do {
            let key = try deriveKey(passphrase: passphrase, salt: salt)
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            return try AES.GCM.open(box, using: key, authenticating: header)
        } catch {
            throw IdentityCipherError.authenticationFailed
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        let passphraseBytes = Data(passphrase.utf8)
        var derived = Data(count: keyByteCount)
        let result = passphraseBytes.withUnsafeBytes { phraseBuffer in
            salt.withUnsafeBytes { saltBuffer in
                derived.withUnsafeMutableBytes { derivedBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        phraseBuffer.bindMemory(to: Int8.self).baseAddress,
                        passphraseBytes.count,
                        saltBuffer.bindMemory(to: UInt8.self).baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        iterationCount,
                        derivedBuffer.bindMemory(to: UInt8.self).baseAddress,
                        keyByteCount
                    )
                }
            }
        }
        guard result == kCCSuccess else { throw IdentityCipherError.keyDerivationFailed }
        // TODO(P2): Minimize and explicitly zero passphrase/derived-key buffers once
        // Swift/CryptoKit provide a reliable non-copying lifecycle for these values.
        return SymmetricKey(data: derived)
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let result = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else { throw IdentityCipherError.randomGenerationFailed }
        return data
    }

    private static func encode(_ value: UInt32) -> Data {
        var bigEndian = value.bigEndian
        return withUnsafeBytes(of: &bigEndian) { Data($0) }
    }

    private static func decodeUInt32(_ data: Data) -> UInt32 {
        data.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func take(_ count: Int, from data: Data, cursor: inout Int) -> Data {
        defer { cursor += count }
        return data[cursor..<(cursor + count)]
    }
}

enum IdentityCipherError: Error {
    case emptyPassphrase
    case invalidContainer
    case randomGenerationFailed
    case keyDerivationFailed
    case authenticationFailed
}
