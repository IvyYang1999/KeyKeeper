import CryptoKit
import Foundation

/// Supplied by the transport's account/record binding, never trusted from ciphertext.
/// The account identifier is authenticated but is not serialized into the cloud blob.
public struct CloudVaultEnvelopeContext: Encodable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumComponentBytes = 1024
    public let container: String
    public let environment: String
    public let account: String
    public let vaultID: UUID
    public let keyID: UUID
    public let revisionID: UUID

    public init(container: String, environment: String, account: String,
                vaultID: UUID, keyID: UUID, revisionID: UUID) {
        self.container = container
        self.environment = environment
        self.account = account
        self.vaultID = vaultID
        self.keyID = keyID
        self.revisionID = revisionID
    }

    fileprivate func validate() throws {
        guard [container, environment, account].allSatisfy({
            !$0.isEmpty && $0.utf8.count <= Self.maximumComponentBytes
        }), environment == "Development" || environment == "Production" else {
            throw CloudVaultEnvelopeError.invalidContext
        }
    }

    public var description: String { "CloudVaultEnvelopeContext(<redacted>)" }
    public var debugDescription: String { description }
}

public enum CloudVaultEnvelopeError: Error, LocalizedError, Equatable {
    case invalidEnvelope, unsupportedVersion, tooLarge, invalidContext, invalidKey, authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope: return "The encrypted sync envelope is invalid."
        case .unsupportedVersion: return "This encrypted sync envelope requires a different version of KeyKeeper."
        case .tooLarge: return "The encrypted sync envelope exceeds this version's size limit."
        case .invalidContext: return "The sync encryption context is invalid."
        case .invalidKey: return "The sync encryption key is invalid."
        case .authenticationFailed: return "The sync envelope could not be authenticated."
        }
    }
}

/// Pure, bounded authenticated transport. No storage, account lookup, or authorization changes.
public enum CloudVaultEnvelope {
    public static let version = 1
    private static let combinedOverhead = 12 + 16 // Standard GCM nonce + authentication tag.
    private static let maximumCombinedBytes = CloudVaultSnapshot.maximumBytes + combinedOverhead
    // JSON holds only a fixed schema number and a Base64 combined box, never context values.
    public static let maximumBytes = ((maximumCombinedBytes + 2) / 3) * 4 + 128

    private struct Wire: Codable {
        let version: Int
        let sealed: Data
    }

    private struct AuthenticationData: Encodable {
        let purpose = "KeyKeeper.CloudVaultEnvelope"
        let version: Int
        let context: CloudVaultEnvelopeContext
    }

    public static func seal(_ snapshot: CloudVaultSnapshot, key: SymmetricKey,
                            context: CloudVaultEnvelopeContext) throws -> Data {
        try validate(key: key, context: context)
        let plaintext = try snapshot.encoded()
        let aad = try authenticationData(context)
        let combined: Data
        do {
            // Omitting nonce asks CryptoKit to generate a fresh standard random nonce.
            let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            guard let bytes = sealed.combined else { throw CloudVaultEnvelopeError.invalidEnvelope }
            combined = bytes
        } catch { throw CloudVaultEnvelopeError.authenticationFailed }
        let data = try CloudVaultSnapshot.encode(Wire(version: version, sealed: combined))
        guard data.count <= maximumBytes else { throw CloudVaultEnvelopeError.tooLarge }
        return data
    }

    public static func open(_ data: Data, key: SymmetricKey,
                            expectedContext: CloudVaultEnvelopeContext) throws -> CloudVaultSnapshot {
        guard data.count <= maximumBytes else { throw CloudVaultEnvelopeError.tooLarge }
        try validate(key: key, context: expectedContext)
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) }
        catch { throw CloudVaultEnvelopeError.invalidEnvelope }
        guard wire.version == version else { throw CloudVaultEnvelopeError.unsupportedVersion }
        guard wire.sealed.count <= maximumCombinedBytes else { throw CloudVaultEnvelopeError.tooLarge }
        guard wire.sealed.count >= combinedOverhead,
              try CloudVaultSnapshot.encode(wire) == data else {
            throw CloudVaultEnvelopeError.invalidEnvelope
        }
        let aad = try authenticationData(expectedContext)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: wire.sealed)
            plaintext = try AES.GCM.open(box, using: key, authenticating: aad)
        } catch { throw CloudVaultEnvelopeError.authenticationFailed }
        return try CloudVaultSnapshot.decode(plaintext)
    }

    private static func validate(key: SymmetricKey, context: CloudVaultEnvelopeContext) throws {
        guard key.bitCount == 256 else { throw CloudVaultEnvelopeError.invalidKey }
        try context.validate()
    }

    private static func authenticationData(_ context: CloudVaultEnvelopeContext) throws -> Data {
        try CloudVaultSnapshot.encode(AuthenticationData(version: version, context: context))
    }
}
