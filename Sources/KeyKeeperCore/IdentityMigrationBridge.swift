import Foundation
import Security
import CryptoKit
import Darwin

/// What the old-identity helper offers the new App, over XPC.
///
/// Only the new App receives the old vault. The service requires the new App's signature, which
/// XPC evaluates from the audit token stamped on each message when it was sent, and the reply goes
/// back over that same connection. Nothing here relies on a process id.
@objc public protocol IdentityMigrationBridgeService {
    /// The complete old source, encoded. `fixture` is the isolated test triple as JSON, or nil for
    /// the real old sources. The reply carries the data and 0, or nil and an error code.
    func captureLegacySource(fixture: Data?, reply: @escaping (Data?, Int32) -> Void)
}

/// The new App's side of the bridge.
public enum IdentityMigrationBridge {
    /// The XPC service bundled at `Contents/XPCServices/KeyKeeperMigrationBridge.xpc`.
    public static let serviceName = "dev.keykeeper.app.migration-bridge"
    static let deadline: TimeInterval = 60

    /// The full old source, values included. Only called after the person confirmed the copy.
    public static func read(fixture: IdentityMigrationFixture? = nil) async throws -> IdentityMigrationSource {
        let payload = try encodeFixture(fixture)
        let bytes: Data = try await call { service, finish in
            service.captureLegacySource(fixture: payload) { data, code in
                if code == 0, let data { finish(.success(data)) } else { finish(.failure(error(code))) }
            }
        }
        return try IdentityMigrationSource.decode(bytes)
    }

    public static func encodeFixture(_ fixture: IdentityMigrationFixture?) throws -> Data? {
        guard let fixture else { return nil }
        return try JSONEncoder().encode(fixture.environment)
    }

    /// The service side: nil means the real old sources; anything else must be the isolated triple.
    public static func decodeFixture(_ data: Data?) throws -> IdentityMigrationFixture? {
        guard let data else { return nil }
        guard data.count <= 4096,
              let environment = try? JSONDecoder().decode([String: String].self, from: data),
              let fixture = try IdentityMigrationFixture.resolve(environment: environment) else {
            throw IdentityMigrationError.identity
        }
        return fixture
    }

    static func error(_ code: Int32) -> IdentityMigrationError {
        IdentityMigrationError.fromExit(code) ?? .unavailable
    }

    private static func call<T>(_ body: @escaping (IdentityMigrationBridgeService,
                                                   @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        try IdentityMigrationSignature.current(.current)
        let connection = NSXPCConnection(serviceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: IdentityMigrationBridgeService.self)
        // Only the old-identity helper may answer: a look-alike service gets no request at all.
        connection.setCodeSigningRequirement(IdentityMigrationSignature.requirementString(.legacy))
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = BridgeOnce()
            let finish: (Result<T, Error>) -> Void = { result in
                if once.claim() { continuation.resume(with: result) }
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { failure in
                let code = (failure as NSError).code
                finish(.failure(code == NSXPCConnectionCodeSigningRequirementFailure
                    ? IdentityMigrationError.identity : IdentityMigrationError.unavailable))
            }
            guard let service = proxy as? IdentityMigrationBridgeService else {
                finish(.failure(IdentityMigrationError.unavailable)); return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                finish(.failure(IdentityMigrationError.unavailable))
            }
            body(service, finish)
        }
    }
}

private final class BridgeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

extension IdentityMigrationSource {
    /// What a completed migration records as the source it copied.
    public func digest() throws -> String {
        SHA256.hash(data: try encoded()).map { String(format: "%02x", $0) }.joined()
    }
}

public enum IdentityMigrationSignature {
    public static func requirementString(_ identity: StorageIdentity) -> String {
        "anchor apple generic and identifier \"\(identity.rawValue)\" and certificate leaf[subject.OU] = \"\(StorageIdentity.team)\""
    }
    private static func requirement(_ identity: StorageIdentity) throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(requirementString(identity) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw IdentityMigrationError.identity }
        return requirement
    }
    public static func current(_ identity: StorageIdentity) throws {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], try requirement(identity)) == errSecSuccess else { throw IdentityMigrationError.identity }
    }
}

extension IdentityMigrationError {
    public var exitCode: Int32 {
        switch self {
        case .unavailable: 70
        case .malformed: 71
        case .unsignedMetadata: 72
        case .activeImport: 73
        case .sourceChanged: 74
        case .destinationConflict: 75
        case .legacyRunning: 76
        case .identity: 77
        }
    }
    static func fromExit(_ value: Int32) -> Self? {
        [Self.unavailable, .malformed, .unsignedMetadata, .activeImport, .sourceChanged, .destinationConflict, .legacyRunning, .identity]
            .first { $0.exitCode == value }
    }
}
