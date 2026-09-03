import Foundation
import Darwin
import Security

public struct EmergencyIdentity: Sendable {
    public let identity: String
    public let recipient: String
    public let mainRecipient: String

    public init(identity: String, recipient: String, mainRecipient: String) {
        self.identity = identity
        self.recipient = recipient
        self.mainRecipient = mainRecipient
    }
}

public struct UnlockedIdentity: Sendable {
    public let identity: String
    public let recipient: String
    public let emergencyRecipient: String

    public init(identity: String, recipient: String, emergencyRecipient: String) {
        self.identity = identity
        self.recipient = recipient
        self.emergencyRecipient = emergencyRecipient
    }
}

public enum AgeVaultError: Error, LocalizedError {
    case alreadyInitialized
    case notInitialized
    case locked
    case ageExecutableUnavailable
    case keyGenerationFailed
    case identityEncryptionFailed
    case identityDecryptionFailed
    case invalidIdentity
    case vaultEncryptionFailed
    case vaultDecryptionFailed
    case invalidVault
    case containerTooLarge
    case emptyPassphrase
    case helperProcessTimedOut

    public var errorDescription: String? {
        switch self {
        case .alreadyInitialized: return "The age vault is already initialized"
        case .notInitialized: return "The age vault is not initialized"
        case .locked: return "The age vault is locked"
        case .ageExecutableUnavailable: return "The age executable is unavailable"
        case .keyGenerationFailed: return "Could not generate an age identity"
        case .identityEncryptionFailed: return "Could not encrypt the age identity"
        case .identityDecryptionFailed: return "Could not unlock the age identity"
        case .invalidIdentity: return "The age identity is invalid"
        case .vaultEncryptionFailed: return "Could not encrypt the age vault"
        case .vaultDecryptionFailed: return "Could not decrypt the age vault"
        case .invalidVault: return "The age vault has an invalid format"
        case .containerTooLarge: return "The encrypted container exceeds the size limit"
        case .emptyPassphrase: return "The passphrase must not be empty"
        case .helperProcessTimedOut: return "The age helper process timed out"
        }
    }
}

public final class AgeVaultStore: @unchecked Sendable {
    private typealias Vault = [String: [String: String]]
    static let maximumEncryptedContainerByteCount = 4 * 1_024 * 1_024
    static let helperProcessTimeout: TimeInterval = 10
    private static let helperTerminationGrace: TimeInterval = 1

    private let directory: URL
    private let identityURL: URL
    private let vaultURL: URL
    private let writeLockURL: URL
    private let ageExecutable: URL
    private let keygenExecutable: URL
    private let configuredHelperProcessTimeout: TimeInterval
    private let atomicWriteInterceptor: @Sendable (URL) throws -> Void
    private let lock = NSLock()
    private var unlockedIdentity: UnlockedIdentity?

    public convenience init(directory: URL) {
        self.init(
            directory: directory,
            ageExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/age"),
            keygenExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
        )
    }

    public convenience init() {
        self.init(directory: KeyKeeperPaths.applicationSupportDirectory)
    }

    init(
        directory: URL,
        ageExecutable: URL,
        keygenExecutable: URL,
        helperProcessTimeout: TimeInterval = AgeVaultStore.helperProcessTimeout,
        atomicWriteInterceptor: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.directory = directory
        identityURL = directory.appendingPathComponent("identity.age")
        vaultURL = directory.appendingPathComponent("vault.age")
        writeLockURL = directory.appendingPathComponent(".age-vault.lock")
        self.ageExecutable = ageExecutable
        self.keygenExecutable = keygenExecutable
        configuredHelperProcessTimeout = helperProcessTimeout
        self.atomicWriteInterceptor = atomicWriteInterceptor
    }

    /// Whether a vault has been created in this directory (both encrypted files present).
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: identityURL.path)
            && FileManager.default.fileExists(atPath: vaultURL.path)
    }

    public func initVault(passphrase: String) throws -> EmergencyIdentity {
        guard !passphrase.isEmpty else { throw AgeVaultError.emptyPassphrase }
        return try withLock {
            try ensureExecutablesExist()
            try createSecureDirectory()
            return try withDirectoryWriteLock {
                let hasIdentity = FileManager.default.fileExists(atPath: identityURL.path)
                let hasVault = FileManager.default.fileExists(atPath: vaultURL.path)
                if hasIdentity != hasVault {
                    // A prior process stopped between the two commits. Removing the orphan
                    // makes initialization explicitly retryable instead of permanently wedged.
                    if hasIdentity { try FileManager.default.removeItem(at: identityURL) }
                    if hasVault { try FileManager.default.removeItem(at: vaultURL) }
                    try syncDirectory()
                } else if hasIdentity {
                    throw AgeVaultError.alreadyInitialized
                }

                let mainIdentity = try generateIdentity()
                let recoveryIdentity = try generateIdentity()
                let mainRecipient = try deriveRecipient(from: mainIdentity)
                let recoveryRecipient = try deriveRecipient(from: recoveryIdentity)
                let identityPlaintext = Data(
                    "# keykeeper emergency recipient: \(recoveryRecipient)\n\(mainIdentity)\n".utf8
                )
                let encryptedIdentity = try encryptIdentity(identityPlaintext, passphrase: passphrase)
                let unlocked = UnlockedIdentity(
                    identity: mainIdentity,
                    recipient: mainRecipient,
                    emergencyRecipient: recoveryRecipient
                )
                let encryptedVault = try encryptVault([:], using: unlocked)

                try atomicWrite(encryptedIdentity, to: identityURL)
                do {
                    try atomicWrite(encryptedVault, to: vaultURL)
                } catch let commitError {
                    do {
                        if FileManager.default.fileExists(atPath: identityURL.path) {
                            try FileManager.default.removeItem(at: identityURL)
                        }
                        if FileManager.default.fileExists(atPath: vaultURL.path) {
                            try FileManager.default.removeItem(at: vaultURL)
                        }
                        try syncDirectory()
                    } catch let cleanupError {
                        throw cleanupError
                    }
                    throw commitError
                }
                unlockedIdentity = unlocked
                return EmergencyIdentity(
                    identity: recoveryIdentity,
                    recipient: recoveryRecipient,
                    mainRecipient: mainRecipient
                )
            }
        }
    }

    @discardableResult
    public func unlock(passphrase: String) throws -> UnlockedIdentity {
        guard !passphrase.isEmpty else { throw AgeVaultError.emptyPassphrase }
        return try withLock {
            try ensureExecutablesExist()
            guard FileManager.default.fileExists(atPath: identityURL.path),
                  FileManager.default.fileExists(atPath: vaultURL.path) else {
                throw AgeVaultError.notInitialized
            }
            let encryptedIdentity = try readEncryptedContainer(from: identityURL)
            let plaintext: Data
            do {
                plaintext = try IdentityCipher.open(encryptedIdentity, passphrase: passphrase)
            } catch {
                throw AgeVaultError.identityDecryptionFailed
            }
            let unlocked = try parseMainIdentity(plaintext)
            _ = try loadVault(using: unlocked)
            unlockedIdentity = unlocked
            return unlocked
        }
    }

    @discardableResult
    public func unlock(emergencyIdentity: EmergencyIdentity) throws -> UnlockedIdentity {
        try withLock {
            try ensureExecutablesExist()
            guard FileManager.default.fileExists(atPath: vaultURL.path) else {
                throw AgeVaultError.notInitialized
            }
            guard try deriveRecipient(from: emergencyIdentity.identity) == emergencyIdentity.recipient else {
                throw AgeVaultError.invalidIdentity
            }
            let unlocked = UnlockedIdentity(
                identity: emergencyIdentity.identity,
                recipient: emergencyIdentity.mainRecipient,
                emergencyRecipient: emergencyIdentity.recipient
            )
            _ = try loadVault(using: unlocked)
            unlockedIdentity = unlocked
            return unlocked
        }
    }

    public func save(
        credentialId: String,
        fieldName: String,
        value: String,
        security: SecurityLevel
    ) throws {
        do {
            try withLock {
                let identity = try requireIdentity()
                try withDirectoryWriteLock {
                    var vault = try loadVault(using: identity)
                    var fields = vault[credentialId] ?? [:]
                    fields[fieldName] = value
                    vault[credentialId] = fields
                    try atomicWrite(try encryptVault(vault, using: identity), to: vaultURL)
                    try persistSecurityMetadata(
                        credentialId: credentialId,
                        fieldName: fieldName,
                        security: security
                    )
                }
            }
        } catch {
            throw mapSaveError(error)
        }
    }

    public func retrieve(credentialId: String, fieldName: String) throws -> String {
        do {
            return try withLock {
                let vault = try loadVault(using: requireIdentity())
                guard let value = vault[credentialId]?[fieldName] else {
                    throw KeychainError.notFound
                }
                return value
            }
        } catch KeychainError.notFound {
            throw KeychainError.notFound
        } catch AgeVaultError.invalidVault {
            throw KeychainError.unexpectedData
        } catch {
            throw KeychainError.retrieveFailed(statusCode(for: error))
        }
    }

    public func delete(credentialId: String, fieldName: String) throws {
        do {
            try withLock {
                let identity = try requireIdentity()
                try withDirectoryWriteLock {
                    var vault = try loadVault(using: identity)
                    if vault[credentialId]?.removeValue(forKey: fieldName) != nil,
                       vault[credentialId]?.isEmpty == true {
                        vault.removeValue(forKey: credentialId)
                    }
                    try atomicWrite(try encryptVault(vault, using: identity), to: vaultURL)
                }
            }
        } catch {
            throw KeychainError.deleteFailed(statusCode(for: error))
        }
    }

    private func requireIdentity() throws -> UnlockedIdentity {
        guard let unlockedIdentity else { throw AgeVaultError.locked }
        return unlockedIdentity
    }

    private func loadVault(using identity: UnlockedIdentity) throws -> Vault {
        let ciphertext = try readEncryptedContainer(from: vaultURL)
        let plaintext = try decryptVault(ciphertext, identity: identity.identity)
        do {
            return try JSONDecoder().decode(Vault.self, from: plaintext)
        } catch {
            throw AgeVaultError.invalidVault
        }
    }

    private func encryptVault(_ vault: Vault, using identity: UnlockedIdentity) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let plaintext = try encoder.encode(vault)
        let result = try run(
            executable: ageExecutable,
            arguments: [
                "--encrypt",
                "--recipient", identity.recipient,
                "--recipient", identity.emergencyRecipient,
            ],
            input: plaintext
        )
        guard result.status == 0 else { throw AgeVaultError.vaultEncryptionFailed }
        return result.output
    }

    private func decryptVault(_ ciphertext: Data, identity: String) throws -> Data {
        let script = "exec 3<&2; exec 2>/dev/null; exec \"$1\" --decrypt --identity /dev/fd/3"
        let result = try run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script, "keykeeper-identity", ageExecutable.path],
            input: ciphertext,
            anonymousInput: Data("\(identity)\n".utf8)
        )
        guard result.status == 0 else { throw AgeVaultError.vaultDecryptionFailed }
        return result.output
    }

    private func encryptIdentity(_ plaintext: Data, passphrase: String) throws -> Data {
        do {
            return try IdentityCipher.seal(plaintext, passphrase: passphrase)
        } catch {
            throw AgeVaultError.identityEncryptionFailed
        }
    }

    private func readEncryptedContainer(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumEncryptedContainerByteCount + 1)
            ?? Data()
        guard data.count <= Self.maximumEncryptedContainerByteCount else {
            throw AgeVaultError.containerTooLarge
        }
        return data
    }

    private func generateIdentity() throws -> String {
        let result = try run(executable: keygenExecutable, arguments: [], input: nil)
        guard result.status == 0,
              let text = String(data: result.output, encoding: .utf8),
              let line = text.split(separator: "\n")
                .first(where: { $0.hasPrefix("AGE-SECRET-KEY-") }) else {
            throw AgeVaultError.keyGenerationFailed
        }
        return String(line)
    }

    private func deriveRecipient(from identity: String) throws -> String {
        let result = try run(
            executable: keygenExecutable,
            arguments: ["--y"],
            input: Data("\(identity)\n".utf8)
        )
        guard result.status == 0,
              let value = String(data: result.output, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              value.hasPrefix("age1") else {
            throw AgeVaultError.invalidIdentity
        }
        return value
    }

    private func parseMainIdentity(_ data: Data) throws -> UnlockedIdentity {
        guard let text = String(data: data, encoding: .utf8) else {
            throw AgeVaultError.invalidIdentity
        }
        let marker = "# keykeeper emergency recipient: "
        let lines = text.split(separator: "\n")
        guard let emergencyLine = lines.first(where: { $0.hasPrefix(marker) }),
              let identityLine = lines.first(where: { $0.hasPrefix("AGE-SECRET-KEY-") }) else {
            throw AgeVaultError.invalidIdentity
        }
        let emergencyRecipient = String(emergencyLine.dropFirst(marker.count))
        let identity = String(identityLine)
        guard emergencyRecipient.hasPrefix("age1") else { throw AgeVaultError.invalidIdentity }
        return UnlockedIdentity(
            identity: identity,
            recipient: try deriveRecipient(from: identity),
            emergencyRecipient: emergencyRecipient
        )
    }

    private func ensureExecutablesExist() throws {
        guard FileManager.default.isExecutableFile(atPath: ageExecutable.path),
              FileManager.default.isExecutableFile(atPath: keygenExecutable.path) else {
            throw AgeVaultError.ageExecutableUnavailable
        }
    }

    private func createSecureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(directory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func atomicWrite(_ data: Data, to target: URL) throws {
        let temporary = directory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        guard chmod(temporary.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let descriptor = open(temporary.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try atomicWriteInterceptor(target)
        guard rename(temporary.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        try syncDirectory()
    }

    private func syncDirectory() throws {
        let descriptor = open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func withDirectoryWriteLock<T>(_ body: () throws -> T) throws -> T {
        let descriptor = open(writeLockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func persistSecurityMetadata(
        credentialId: String,
        fieldName: String,
        security: SecurityLevel
    ) throws {
        let store = MetaStore(directory: directory)
        var meta = try store.load()
        if var credential = meta.credentials[credentialId] {
            credential.security = security
            if credential.fields[fieldName] == nil {
                credential.fields[fieldName] = CredentialField(secret: true)
            } else {
                credential.fields[fieldName]?.value = nil
                credential.fields[fieldName]?.secret = true
            }
            meta.credentials[credentialId] = credential
        } else {
            let day = ISO8601DateFormatter().string(from: Date()).prefix(10)
            meta.credentials[credentialId] = Credential(
                label: credentialId,
                notes: "",
                links: [],
                fields: [fieldName: CredentialField(secret: true)],
                security: security,
                created: String(day),
                updated: String(day)
            )
        }
        try store.save(meta)
    }

    private func mapSaveError(_ error: Error) -> KeychainError {
        if case let KeychainError.saveFailed(status) = error {
            return .saveFailed(status)
        }
        return .saveFailed(statusCode(for: error))
    }

    private func statusCode(for error: Error) -> OSStatus {
        if let posix = error as? POSIXError {
            return OSStatus(posix.code.rawValue)
        }
        switch error {
        case AgeVaultError.vaultDecryptionFailed, AgeVaultError.invalidVault:
            return errSecDecode
        default:
            return errSecInternalError
        }
    }

    private struct ProcessResult {
        let status: Int32
        let output: Data
    }

    private func run(
        executable: URL,
        arguments: [String],
        input: Data?,
        environment: [String: String] = [:],
        anonymousInput: Data? = nil
    ) throws -> ProcessResult {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()
        let standardError = anonymousInput == nil ? Pipe() : nil
        let anonymousPipe = anonymousInput.map { _ in Pipe() }
        process.executableURL = executable
        if let anonymousPipe {
            process.arguments = arguments
            // Process explicitly dup2s this anonymous pipe's read end onto child FD 2.
            // The child consumes it as an input FD, so diagnostics on stderr are unavailable
            // for these secret-bearing invocations and are deliberately never logged.
            process.standardError = anonymousPipe.fileHandleForReading
        } else {
            process.arguments = arguments
            process.standardError = standardError
        }
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        let childEnvironment = environment
        if !childEnvironment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(childEnvironment) {
                _, override in override
            }
        }

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminationSemaphore.signal() }

        do {
            try process.run()
        } catch {
            throw AgeVaultError.ageExecutableUnavailable
        }

        let outputReader = ProcessPipeReader()
        outputReader.start(reading: standardOutput.fileHandleForReading)
        let errorReader = standardError.map { pipe -> ProcessPipeReader in
            let reader = ProcessPipeReader()
            reader.start(reading: pipe.fileHandleForReading)
            return reader
        }

        if let anonymousInput, let anonymousPipe {
            try? anonymousPipe.fileHandleForReading.close()
            _ = fcntl(anonymousPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? anonymousPipe.fileHandleForWriting.write(contentsOf: anonymousInput)
                try? anonymousPipe.fileHandleForWriting.close()
            }
        }
        _ = fcntl(standardInput.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            if let input {
                try? standardInput.fileHandleForWriting.write(contentsOf: input)
            }
            try? standardInput.fileHandleForWriting.close()
        }

        let waitResult = terminationSemaphore.wait(
            timeout: .now() + max(0, configuredHelperProcessTimeout)
        )
        if waitResult == .timedOut {
            process.terminate()
            if terminationSemaphore.wait(
                timeout: .now() + Self.helperTerminationGrace
            ) == .timedOut {
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            _ = try? outputReader.waitForData()
            _ = try? errorReader?.waitForData()
            throw AgeVaultError.helperProcessTimedOut
        }

        process.waitUntilExit()
        let output = try outputReader.waitForData()
        _ = try errorReader?.waitForData()
        return ProcessResult(status: process.terminationStatus, output: output)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // TODO(P2): Add a monotonic authenticated vault version to detect rollback to an older ciphertext.
}

private final class ProcessPipeReader: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func start(reading handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let readResult = Result { try handle.readToEnd() ?? Data() }
            lock.lock()
            result = readResult
            lock.unlock()
            group.leave()
        }
    }

    func waitForData() throws -> Data {
        group.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        return try result?.get() ?? Data()
    }
}
