import Foundation
import CryptoKit
import KeyKeeperCore
import Security
import LocalAuthentication

final class ProbeDirectoryLock {
    private let fd: Int32
    init(root: URL) throws {
        fd = Darwin.open(root.appendingPathComponent(".probe.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeFailure.isolation }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd); throw ProbeFailure.isolation
        }
    }
    deinit { flock(fd, LOCK_UN); close(fd) }
}

struct ProbePayload: Codable {
    let vaultID: UUID
    let keyID: UUID
    let revisionID: UUID
    let ciphertext: Data

    func context(account: String, environment: String) -> CloudVaultEnvelopeContext {
        .init(container: ProbeOptions.container, environment: environment, account: account,
              vaultID: vaultID, keyID: keyID, revisionID: revisionID)
    }
}

struct ProbeState: Codable {
    let schema: Int
    let runID: UUID
    let accountHash: String
    let environment: String
    var confirmed: ProbePayload?
    var pending: ProbePayload?

    static func load(options: ProbeOptions, account: String, environment: String) throws -> Self {
        let url = options.root.appendingPathComponent("state.json")
        let hash = digest(Data(account.utf8))
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw ProbeFailure.isolation }
            return .init(schema: 1, runID: options.runID, accountHash: hash, environment: environment)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,
              (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 2 * 1024 * 1024,
              (attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw ProbeFailure.isolation }
        let bytes = try Data(contentsOf: url)
        let state = try JSONDecoder().decode(Self.self, from: bytes)
        guard state.schema == 1, state.runID == options.runID, state.accountHash == hash,
              state.environment == environment,
              [state.confirmed, state.pending].compactMap({ $0 }).allSatisfy({
                  $0.vaultID == options.runID && $0.ciphertext.count <= 1024 * 1024
              }), try state.encoded() == bytes else { throw ProbeFailure.corrupt }
        return state
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    func save(root: URL) throws {
        let url = root.appendingPathComponent("state.json")
        let temporary = root.appendingPathComponent(".state-" + UUID().uuidString)
        let bytes = try encoded()
        let fd = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ProbeFailure.isolation }
        defer { close(fd) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard written > 0 else { throw ProbeFailure.isolation }
                offset += written
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ProbeFailure.isolation }
        let directory = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw ProbeFailure.isolation }
        defer { close(directory) }
        guard fsync(directory) == 0 else { throw ProbeFailure.isolation }
    }

    static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }

    static func selfTest(payload: ProbePayload) throws {
        let root = URL(fileURLWithPath: "/private/tmp/keykeeper-cloud-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) } // This invocation's disposable, synthetic fixture only.
        let options = try ProbeOptions(arguments: ["seed", "--synthetic", "--run-id", payload.vaultID.uuidString, "--root", root.path])
        do { try options.validateRoot() } catch { print("SELFTEST_FAIL root"); throw error }
        let owner: ProbeDirectoryLock
        do { owner = try ProbeDirectoryLock(root: root) } catch { print("SELFTEST_FAIL lock"); throw error }
        defer { withExtendedLifetime(owner) {} }
        do { _ = try ProbeDirectoryLock(root: root); throw ProbeFailure.corrupt }
        catch ProbeFailure.isolation { }
        var state = try load(options: options, account: "test-account", environment: "Production")
        state.pending = payload
        do { try state.save(root: root) } catch { print("SELFTEST_FAIL save"); throw error }
        let before = try Data(contentsOf: root.appendingPathComponent("state.json"))
        let restored: ProbeState
        do { restored = try load(options: options, account: "test-account", environment: "Production") } catch { print("SELFTEST_FAIL load"); throw error }
        guard restored.pending?.ciphertext == payload.ciphertext else { throw ProbeFailure.corrupt }
        // Real journal seam: account change after verify cannot clear pending on disk.
        let fence = ProbeAccountFence(), permit = try fence.capture()
        fence.invalidate()
        do {
            try fence.withValid(permit) {
                state.confirmed = payload; state.pending = nil
                try state.save(root: root)
            }
            throw ProbeFailure.corrupt
        } catch ProbeFailure.account { }
        guard try Data(contentsOf: root.appendingPathComponent("state.json")) == before,
              try load(options: options, account: "test-account", environment: "Production").pending != nil else {
            throw ProbeFailure.corrupt
        }
        do { _ = try load(options: options, account: "other-account", environment: "Production"); throw ProbeFailure.unavailable }
        catch ProbeFailure.corrupt { }
        guard try Data(contentsOf: root.appendingPathComponent("state.json")) == before else { throw ProbeFailure.corrupt }
    }
}

enum ProbeKeychain {
    private static func query(runID: UUID, keyID: UUID) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.keykeeper.test.cloud." + runID.uuidString,
         kSecAttrAccount as String: keyID.uuidString,
         kSecAttrAccessGroup as String: ProbeOptions.applicationID,
         kSecAttrSynchronizable as String: true,
         kSecUseDataProtectionKeychain as String: true,
         kSecUseAuthenticationContext as String: context]
    }

    static func read(runID: UUID, keyID: UUID) throws -> SymmetricKey {
        var q = query(runID: runID, keyID: keyID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { throw ProbeFailure.missingKey }
        guard code == errSecSuccess else { throw ProbeKeychainStatus(code: code) }
        guard let bytes = result as? Data, bytes.count == 32 else { throw ProbeFailure.keychain }
        return SymmetricKey(data: bytes)
    }

    /// Immutable random-ID root keys. No update or delete API exists in this probe.
    static func create(runID: UUID, keyID: UUID, key: SymmetricKey) throws {
        var q = query(runID: runID, keyID: keyID)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        let code = SecItemAdd(q as CFDictionary, nil)
        guard code == errSecSuccess else { throw ProbeKeychainStatus(code: code) }
        let restored = try read(runID: runID, keyID: keyID)
        guard restored.withUnsafeBytes({ Data($0) }) == key.withUnsafeBytes({ Data($0) }) else { throw ProbeFailure.keychain }
    }
}

struct ProbeKeychainStatus: Error { let code: OSStatus }
