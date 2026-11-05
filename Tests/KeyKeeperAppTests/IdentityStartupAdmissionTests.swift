import XCTest
import KeyKeeperCore
@testable import KeyKeeperApp

@MainActor
final class IdentityStartupAdmissionTests: XCTestCase {
    /// The real coordinator writes into this; every create counts.
    private final class MemoryDestination: IdentityMigrationDestination {
        var items: [IdentityMigrationItem: Data] = [:], files: [String: Data] = [:]
        var journal: Data?
        var writes = 0
        func readItem(_ item: IdentityMigrationItem) throws -> Data? { items[item] }
        func createItem(_ item: IdentityMigrationItem, data: Data) throws { writes += 1; items[item] = data }
        func readFile(_ name: String) throws -> Data? { files[name] }
        func createFile(_ name: String, data: Data) throws { writes += 1; files[name] = data }
        func readJournal() throws -> Data? { journal }
        func writeJournal(_ data: Data, replacingExisting: Bool) throws { writes += 1; journal = data }
    }

    private let empty = IdentityMigrationSource(preferences: Data("{}".utf8))
    /// Synthetic old data with no secret: an empty edit history is enough to be "old data".
    private let legacy = IdentityMigrationSource(metadataHistory: Data("[]".utf8), preferences: Data("{}".utf8))

    /// Production wiring around a real coordinator; only the old folder and the helper are faked.
    private func admission(destination: MemoryDestination, filesExist: @escaping () throws -> Bool,
                           read: @escaping () throws -> IdentityMigrationSource,
                           reads: UnsafeMutablePointer<Int>, starts: UnsafeMutablePointer<Int>) -> IdentityStartupAdmission {
        let coordinator = IdentityMigrationCoordinator(destination: destination)
        return IdentityStartupAdmission(operations: .init(
            status: { try coordinator.status() },
            recover: { _ = try coordinator.recover() },
            applyPreferences: { try coordinator.applyPreferences(to: self.scratchDefaults()) },
            legacyFilesExist: filesExist,
            readSource: { reads.pointee += 1; return try read() },
            migrate: { source, expected in _ = try coordinator.migrate(source: source, expectedLegacyData: expected) }),
            onReady: { starts.pointee += 1 })
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "com.keykeeper.test.admission"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        UserDefaults.standard.removePersistentDomain(forName: name)
        return UserDefaults(suiteName: name)!
    }

    private func counters() -> (UnsafeMutablePointer<Int>, UnsafeMutablePointer<Int>) {
        let reads = UnsafeMutablePointer<Int>.allocate(capacity: 1), starts = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        reads.pointee = 0; starts.pointee = 0
        addTeardownBlock { reads.deallocate(); starts.deallocate() }
        return (reads, starts)
    }

    /// 【验收 R1】确认之前，完整来源（含 key 值、审批、网站登录）的读取次数必须为 0；
    /// 分流只看旧文件夹里有没有文件名。只有确认之后才读一次。
    func testNoSecretBearingReadBeforeConfirmation() async {
        for (exists, expected) in [(false, IdentityStartupAdmission.Stage.firstInstall), (true, .legacyFound)] {
            let destination = MemoryDestination(), (reads, starts) = counters()
            let admission = admission(destination: destination, filesExist: { exists },
                                      read: { exists ? self.legacy : self.empty }, reads: reads, starts: starts)
            admission.start()
            XCTAssertEqual(admission.stage, expected)
            XCTAssertEqual(reads.pointee, 0, "The full source must not be read before the person confirms")
            XCTAssertEqual(destination.writes, 0)
            admission.retry(); admission.start()
            XCTAssertEqual(reads.pointee, 0)
            await admission.prepare()
            XCTAssertEqual(reads.pointee, 1)
            XCTAssertTrue(admission.admitted); XCTAssertEqual(starts.pointee, 1)
            admission.start(); await admission.prepare()
            XCTAssertEqual(starts.pointee, 1)
        }
    }

    /// 【验收 R2】看到「准备这台 Mac」并确认，读到的却是旧数据（或反过来）：一个字节都不写，
    /// 换成对应的页面重新确认；再次确认后才复制。
    func testConfirmedKindIsBoundToTheWrite() async {
        for (filesExist, actual, firstStage, nextStage) in [
            (false, legacy, IdentityStartupAdmission.Stage.firstInstall, IdentityStartupAdmission.Stage.legacyFound),
            (true, empty, .legacyFound, .firstInstall)
        ] {
            let destination = MemoryDestination(), (reads, starts) = counters()
            let admission = admission(destination: destination, filesExist: { filesExist },
                                      read: { actual }, reads: reads, starts: starts)
            admission.start()
            XCTAssertEqual(admission.stage, firstStage)
            await admission.prepare()
            XCTAssertEqual(destination.writes, 0, "Nothing may be written for a kind the person did not confirm")
            XCTAssertNil(destination.journal)
            XCTAssertFalse(admission.admitted)
            XCTAssertEqual(admission.stage, nextStage)
            XCTAssertTrue(admission.sourceChangedSinceConfirmation)
            await admission.prepare()
            XCTAssertTrue(admission.admitted)
            XCTAssertFalse(admission.sourceChangedSinceConfirmation)
            XCTAssertEqual(starts.pointee, 1)
        }
    }

    /// 旧文件夹查不了、确认时旧 App 在运行、完整读取失败：都停在失败页，不当成空来源，不写入。
    func testUnreadableSourceNeverBecomesAnEmptyStore() async {
        let destination = MemoryDestination(), (reads, starts) = counters()
        var folderError: IdentityMigrationError? = .unavailable
        var readError: IdentityMigrationError? = .legacyRunning
        let admission = admission(destination: destination,
            filesExist: { if let folderError { throw folderError }; return false },
            read: { if let readError { throw readError }; return self.empty }, reads: reads, starts: starts)
        admission.start()
        guard case .failed(let unreadable) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(unreadable.kind, .sourceUnreadable)
        await admission.prepare()
        XCTAssertEqual(reads.pointee, 0, "No setup is offered while the folder cannot be checked")

        folderError = nil
        admission.retry()
        XCTAssertEqual(admission.stage, .firstInstall)
        await admission.prepare()
        guard case .failed(let running) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(running.kind, .sourceUnreadable)
        XCTAssertEqual(running.detail, IdentityMigrationError.legacyRunning.errorDescription)

        for error in [IdentityMigrationError.unavailable, .identity] {
            readError = error
            admission.retry(); await admission.prepare()
            guard case .failed(let failure) = admission.stage else { return XCTFail("\(admission.stage)") }
            XCTAssertEqual(failure.kind, .sourceUnreadable)
        }
        readError = .unsignedMetadata
        admission.retry(); await admission.prepare()
        guard case .failed(let unsupported) = admission.stage else { return XCTFail("\(admission.stage)") }
        XCTAssertEqual(unsupported.kind, .unsupported)
        XCTAssertEqual(destination.writes, 0)
        XCTAssertFalse(admission.admitted); XCTAssertEqual(starts.pointee, 0)

        readError = nil
        admission.retry(); await admission.prepare()
        XCTAssertTrue(admission.admitted, "After the old App quits, trying again works")
    }

    func testPendingRecoveryAndPreferencesMustFinishBeforeAnyServiceStarts() {
        var migrationStatus = IdentityMigrationStatus.pending
        var events: [String] = []
        let admission = IdentityStartupAdmission(operations: .init(
            status: { migrationStatus },
            recover: { events.append("recover"); migrationStatus = .ready },
            applyPreferences: { events.append("preferences") },
            legacyFilesExist: { XCTFail("An interrupted copy must not look at the source again"); return false },
            readSource: { XCTFail("Must not read another source"); return self.empty },
            migrate: { _, _ in XCTFail("Must not migrate again") }), onReady: { events.append("services") })
        admission.start()
        XCTAssertEqual(events, ["recover", "preferences", "services"])
    }

    func testUnavailableMigrationNeverLooksLikeEmptyReadyStore() async {
        for failingPhase in [IdentityMigrationStatus.required, .pending, .ready] {
            let admission = IdentityStartupAdmission(operations: .init(
                status: { failingPhase }, recover: { throw IdentityMigrationError.unavailable },
                applyPreferences: { throw IdentityMigrationError.unavailable },
                legacyFilesExist: { false }, readSource: { self.empty },
                migrate: { _, _ in throw IdentityMigrationError.unavailable }), onReady: { XCTFail("Not admitted") })
            admission.start(); await admission.prepare()
            XCTAssertFalse(admission.admitted)
            guard case .failed(let failure) = admission.stage else { return XCTFail("\(failingPhase): \(admission.stage)") }
            XCTAssertEqual(failure.kind, .storage)
        }
    }
}
