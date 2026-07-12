import Foundation
import XCTest
@testable import KeyKeeperCore

final class AgeVaultStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age") &&
                FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/age-keygen"),
            "The system age executables are unavailable."
        )
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("keykeeper-age-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testInitSaveRetrieveRoundTrip() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "correct horse placeholder")
        try store.save(
            credentialId: "service-a", fieldName: "access",
            value: "opaque-value-one", security: .standard
        )

        XCTAssertEqual(
            try store.retrieve(credentialId: "service-a", fieldName: "access"),
            "opaque-value-one"
        )
    }

    func testEmergencyIdentityCanDecryptVault() throws {
        let store = makeStore()
        let emergency = try store.initVault(passphrase: "primary phrase placeholder")
        try store.save(
            credentialId: "service-a", fieldName: "access",
            value: "recovery-only-value", security: .standard
        )

        let recoveredStore = makeStore()
        _ = try recoveredStore.unlock(emergencyIdentity: emergency)

        XCTAssertEqual(
            try recoveredStore.retrieve(credentialId: "service-a", fieldName: "access"),
            "recovery-only-value"
        )
    }

    func testWrongPassphraseFailsUnlockWithoutLeakingPassphrase() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "accepted phrase placeholder")
        let lockedStore = makeStore()

        XCTAssertThrowsError(try lockedStore.unlock(passphrase: "rejected phrase placeholder")) { error in
            XCTAssertFalse(String(describing: error).contains("rejected phrase placeholder"))
        }
    }

    func testIdentityCipherUsesRandomSaltAndNonce() throws {
        let plaintext = Data("private identity placeholder".utf8)

        let first = try IdentityCipher.seal(plaintext, passphrase: "phrase placeholder")
        let second = try IdentityCipher.seal(plaintext, passphrase: "phrase placeholder")

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(
            try IdentityCipher.open(first, passphrase: "phrase placeholder"),
            plaintext
        )
        XCTAssertEqual(
            try IdentityCipher.open(second, passphrase: "phrase placeholder"),
            plaintext
        )
    }

    func testIdentityCipherRejectsWrongPassphraseAndTampering() throws {
        let sealed = try IdentityCipher.seal(
            Data("private identity placeholder".utf8),
            passphrase: "accepted phrase placeholder"
        )

        XCTAssertThrowsError(
            try IdentityCipher.open(sealed, passphrase: "rejected phrase placeholder")
        )

        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(
            try IdentityCipher.open(tampered, passphrase: "accepted phrase placeholder")
        )
    }

    func testDeleteThenRetrieveThrowsNotFound() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "delete phrase placeholder")
        try store.save(
            credentialId: "service-a", fieldName: "access",
            value: "disposable-value", security: .standard
        )

        try store.delete(credentialId: "service-a", fieldName: "access")

        XCTAssertThrowsError(try store.retrieve(credentialId: "service-a", fieldName: "access")) { error in
            guard case KeychainError.notFound = error else {
                return XCTFail("Expected KeychainError.notFound")
            }
        }
    }

    func testMultipleFieldsAndCredentialsDoNotInterfere() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "collection phrase placeholder")
        try store.save(credentialId: "service-a", fieldName: "first", value: "alpha-placeholder", security: .standard)
        try store.save(credentialId: "service-a", fieldName: "second", value: "beta-placeholder", security: .standard)
        try store.save(credentialId: "service-b", fieldName: "first", value: "gamma-placeholder", security: .strict)

        XCTAssertEqual(try store.retrieve(credentialId: "service-a", fieldName: "first"), "alpha-placeholder")
        XCTAssertEqual(try store.retrieve(credentialId: "service-a", fieldName: "second"), "beta-placeholder")
        XCTAssertEqual(try store.retrieve(credentialId: "service-b", fieldName: "first"), "gamma-placeholder")
    }

    func testFailedAtomicReplacementPreservesPreviousVault() throws {
        let initialStore = makeStore()
        _ = try initialStore.initVault(passphrase: "atomic phrase placeholder")
        try initialStore.save(
            credentialId: "service-a", fieldName: "access",
            value: "stable-old-value", security: .standard
        )

        let failingStore = makeStore(atomicWriteInterceptor: { target in
            if target.lastPathComponent == "vault.age" {
                throw SimulatedWriteError()
            }
        })
        _ = try failingStore.unlock(passphrase: "atomic phrase placeholder")

        XCTAssertThrowsError(
            try failingStore.save(
                credentialId: "service-a", fieldName: "access",
                value: "uncommitted-new-value", security: .standard
            )
        ) { error in
            guard case KeychainError.saveFailed = error else {
                return XCTFail("Expected KeychainError.saveFailed")
            }
        }

        let verificationStore = makeStore()
        _ = try verificationStore.unlock(passphrase: "atomic phrase placeholder")
        XCTAssertEqual(
            try verificationStore.retrieve(credentialId: "service-a", fieldName: "access"),
            "stable-old-value"
        )
    }

    func testEncryptedFilesContainNeitherSecretValueNorPrivateIdentities() throws {
        let store = makeStore()
        let emergency = try store.initVault(passphrase: "disk phrase placeholder")
        let unlocked = try store.unlock(passphrase: "disk phrase placeholder")
        try store.save(
            credentialId: "service-a", fieldName: "access",
            value: "never-on-disk-plaintext", security: .strict
        )

        let identityBytes = try Data(contentsOf: directory.appendingPathComponent("identity.age"))
        let vaultBytes = try Data(contentsOf: directory.appendingPathComponent("vault.age"))

        for forbidden in [
            Data("never-on-disk-plaintext".utf8),
            Data("disk phrase placeholder".utf8),
            Data(emergency.identity.utf8),
            Data(unlocked.identity.utf8),
        ] {
            XCTAssertNil(identityBytes.range(of: forbidden))
            XCTAssertNil(vaultBytes.range(of: forbidden))
        }
    }

    func testIdentityFileUsesSelfContainedAuthenticatedContainer() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "container phrase placeholder")

        let identityBytes = try Data(contentsOf: directory.appendingPathComponent("identity.age"))

        XCTAssertTrue(identityBytes.starts(with: Data("KEYKID01".utf8)))
        XCTAssertFalse(identityBytes.starts(with: Data("age-encryption.org/".utf8)))
    }

    func testPrivateInputsNeverCreateNamedFIFOs() throws {
        let observer = NamedFIFOObserver(directory: directory)
        observer.start()
        defer { observer.stop() }

        let store = makeStore()
        _ = try store.initVault(passphrase: "fifo audit phrase placeholder")
        let lockedStore = makeStore()
        _ = try lockedStore.unlock(passphrase: "fifo audit phrase placeholder")
        try lockedStore.save(
            credentialId: "service-a", fieldName: "access",
            value: "fifo-audit-value", security: .standard
        )
        observer.stop()

        XCTAssertFalse(observer.didObserveFIFO, "Named FIFO existed during a private operation")
        for item in try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) {
            var info = stat()
            XCTAssertEqual(lstat(item.path, &info), 0)
            XCTAssertNotEqual(info.st_mode & S_IFMT, S_IFIFO, "Named FIFO found in vault directory")
        }
    }

    func testDeleteFailureMapsToKeychainDeleteFailed() throws {
        let initialStore = makeStore()
        _ = try initialStore.initVault(passphrase: "delete failure phrase placeholder")
        try initialStore.save(
            credentialId: "service-a", fieldName: "access",
            value: "delete-failure-value", security: .standard
        )
        let failingStore = makeStore(atomicWriteInterceptor: { target in
            if target.lastPathComponent == "vault.age" { throw SimulatedWriteError() }
        })
        _ = try failingStore.unlock(passphrase: "delete failure phrase placeholder")

        XCTAssertThrowsError(
            try failingStore.delete(credentialId: "service-a", fieldName: "access")
        ) { error in
            guard case KeychainError.deleteFailed = error else {
                return XCTFail("Expected KeychainError.deleteFailed")
            }
        }
    }

    func testSavePersistsSecurityInMetadataAndValueOnlyInVault() throws {
        var meta = MetaFile()
        meta.credentials["service-a"] = Credential(
            label: "Service A", notes: "", links: [],
            fields: ["access": CredentialField(secret: true)],
            security: .standard, created: "2026-07-11", updated: "2026-07-11"
        )
        try MetaStore(directory: directory).save(meta)

        let store = makeStore()
        _ = try store.initVault(passphrase: "metadata phrase placeholder")
        try store.save(
            credentialId: "service-a", fieldName: "access",
            value: "metadata-audit-value", security: .strict
        )

        let loaded = try MetaStore(directory: directory).load()
        XCTAssertEqual(loaded.credentials["service-a"]?.security, .strict)
        XCTAssertNil(loaded.credentials["service-a"]?.fields["access"]?.value)
        XCTAssertNil(try Data(contentsOf: directory.appendingPathComponent("meta.json"))
            .range(of: Data("metadata-audit-value".utf8)))
    }

    func testCorruptVaultRetrieveMapsToKeychainRetrieveFailed() throws {
        let store = makeStore()
        _ = try store.initVault(passphrase: "corruption phrase placeholder")
        try Data("corrupt ciphertext placeholder".utf8)
            .write(to: directory.appendingPathComponent("vault.age"))

        XCTAssertThrowsError(try store.retrieve(credentialId: "service-a", fieldName: "access")) { error in
            guard case KeychainError.retrieveFailed = error else {
                return XCTFail("Expected KeychainError.retrieveFailed")
            }
        }
    }

    func testTwoInstancesConcurrentSaveDoesNotLoseEitherField() throws {
        let initialStore = makeStore()
        _ = try initialStore.initVault(passphrase: "concurrency phrase placeholder")

        let first = makeStore(atomicWriteInterceptor: { target in
            if target.lastPathComponent == "vault.age" { usleep(200_000) }
        })
        let second = makeStore(atomicWriteInterceptor: { target in
            if target.lastPathComponent == "vault.age" { usleep(200_000) }
        })
        _ = try first.unlock(passphrase: "concurrency phrase placeholder")
        _ = try second.unlock(passphrase: "concurrency phrase placeholder")

        let start = DispatchSemaphore(value: 0)
        let finished = expectation(description: "both saves finish")
        finished.expectedFulfillmentCount = 2
        let failures = ErrorCollector()
        DispatchQueue.global().async {
            start.wait()
            do {
                try first.save(
                    credentialId: "service-a", fieldName: "first",
                    value: "concurrent-first", security: .standard
                )
            } catch { failures.append(error) }
            finished.fulfill()
        }
        DispatchQueue.global().async {
            start.wait()
            do {
                try second.save(
                    credentialId: "service-a", fieldName: "second",
                    value: "concurrent-second", security: .standard
                )
            } catch { failures.append(error) }
            finished.fulfill()
        }
        start.signal()
        start.signal()
        wait(for: [finished], timeout: 10)
        XCTAssertTrue(failures.isEmpty)

        let verifier = makeStore()
        _ = try verifier.unlock(passphrase: "concurrency phrase placeholder")
        XCTAssertEqual(try verifier.retrieve(credentialId: "service-a", fieldName: "first"), "concurrent-first")
        XCTAssertEqual(try verifier.retrieve(credentialId: "service-a", fieldName: "second"), "concurrent-second")
    }

    func testInitRecoversIdentityOnlyHalfInitialization() throws {
        let interrupted = makeStore()
        _ = try interrupted.initVault(passphrase: "interrupted phrase placeholder")
        try FileManager.default.removeItem(at: directory.appendingPathComponent("vault.age"))

        let recovered = makeStore()
        _ = try recovered.initVault(passphrase: "recovered phrase placeholder")

        let lockedStore = makeStore()
        XCTAssertNoThrow(try lockedStore.unlock(passphrase: "recovered phrase placeholder"))
    }

    private func makeStore(
        atomicWriteInterceptor: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) -> AgeVaultStore {
        AgeVaultStore(
            directory: directory,
            ageExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/age"),
            keygenExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen"),
            atomicWriteInterceptor: atomicWriteInterceptor
        )
    }
}

private struct SimulatedWriteError: Error {}

private final class ErrorCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [Error] = []

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return errors.isEmpty
    }

    func append(_ error: Error) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }
}

private final class NamedFIFOObserver: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var running = false
    private var observed = false

    init(directory: URL) {
        self.directory = directory
    }

    var didObserveFIFO: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func start() {
        lock.lock()
        running = true
        lock.unlock()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            while isRunning {
                scan()
                usleep(1_000)
            }
            scan()
        }
    }

    func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        lock.unlock()
        if wasRunning { group.wait() }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func scan() {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for item in items {
            var info = stat()
            if lstat(item.path, &info) == 0, info.st_mode & S_IFMT == S_IFIFO {
                lock.lock()
                observed = true
                lock.unlock()
                return
            }
        }
    }
}
