import XCTest
import Foundation
@testable import KeyKeeperCore

final class IdentityMigrationTests: XCTestCase {
    private final class Destination: IdentityMigrationDestination {
        var items: [IdentityMigrationItem: Data] = [:], files: [String: Data] = [:]
        var journal: Data?
        var writeCount = 0, failAt: Int?, failAfterWrite = false
        func mutation(_ action: () throws -> Void) throws {
            writeCount += 1
            if failAt == writeCount && !failAfterWrite { throw IdentityMigrationError.unavailable }
            try action()
            if failAt == writeCount { throw IdentityMigrationError.unavailable }
        }
        func readItem(_ item: IdentityMigrationItem) throws -> Data? { items[item] }
        func createItem(_ item: IdentityMigrationItem, data: Data) throws {
            try mutation { guard items[item] == nil else { throw IdentityMigrationError.destinationConflict }; items[item] = data }
        }
        func readFile(_ name: String) throws -> Data? { files[name] }
        func createFile(_ name: String, data: Data) throws {
            try mutation { guard files[name] == nil else { throw IdentityMigrationError.destinationConflict }; files[name] = data }
        }
        func readJournal() throws -> Data? { journal }
        func writeJournal(_ data: Data, replacingExisting: Bool) throws {
            try mutation { guard replacingExisting == (journal != nil) else { throw IdentityMigrationError.destinationConflict }; journal = data }
        }
    }
    private func fixture() throws -> IdentityMigrationSource {
        let credential = Credential(label: "Fixture", notes: "Preserved note", links: ["https://example.com"],
            fields: ["api-key": .init(secret: true), "missing": .init(secret: true), "region": .init(value: "fixture-region", secret: false)],
            security: .strict, created: "2026-11-02", updated: "2026-11-02", aliases: ["old-fixture"], provider: "openai")
        var meta = MetaFile(storeInitialized: true, credentials: ["fixture": credential])
        let key = Data(repeating: 9, count: 32)
        meta.integrity = try MetaIntegrity.mac(for: meta, key: key)
        let blob = KeychainBlobStore.Blob(version: 1, credentials: ["fixture": ["api-key": "synthetic-value", "orphan": "synthetic-orphan"], "orphan-group": ["value": "synthetic-other"]])
        let approvals = ApprovalDocument(mode: .permissive, approvals: [.init(subject: .init(fingerprint: "fixture", displayName: "Fixture"),
            target: .credential(id: "fixture", fields: nil), duration: .always)],
            auditEvents: [.init(timestamp: Date(timeIntervalSince1970: 1_700_000_000), credentialId: "fixture", fieldName: "api-key",
                subjectFingerprint: "fixture", subjectDisplayName: "Fixture", mode: .enforced, decision: "approved")],
            reviewerSettings: .init(enabled: true, apiKey: "synthetic-reviewer"))
        return try .init(metadata: IdentityMigrationCodec.encode(meta), values: IdentityMigrationCodec.encode(blob), integrityKey: key,
            approvals: IdentityMigrationCodec.encode(approvals, datesISO8601: true), preferences: Data(#"{"approvalSoundEnabled":false,"interfaceLanguage":"en"}"#.utf8))
    }
    func testMigrationPreservesRawOrphansMissingFieldsMetadataAndLocalSettings() throws {
        let source = try fixture(), before = try source.encoded(), destination = Destination()
        let coordinator = IdentityMigrationCoordinator(destination: destination)
        XCTAssertEqual(try coordinator.status(), .required)
        let summary = try coordinator.migrate(source: source)
        XCTAssertEqual(summary.credentialCount, 1); XCTAssertEqual(summary.missingValueCount, 1)
        XCTAssertEqual(summary.transferredGrants, 0)
        XCTAssertEqual(destination.items[.values], source.values)
        XCTAssertNotEqual(destination.items[.metadataKey], source.integrityKey)
        let meta = try IdentityMigrationCodec.decode(MetaFile.self, from: XCTUnwrap(destination.files["meta.json"]))
        XCTAssertEqual(meta.credentials["fixture"]?.notes, "Preserved note")
        XCTAssertEqual(meta.credentials["fixture"]?.aliases, ["old-fixture"])
        XCTAssertEqual(MetaIntegrity.verify(meta, key: try XCTUnwrap(destination.items[.metadataKey])), .intact)
        let approvals = try IdentityMigrationCodec.decode(ApprovalDocument.self, from: XCTUnwrap(destination.items[.approvals]), datesISO8601: true)
        XCTAssertEqual(approvals.mode, .enforced); XCTAssertTrue(approvals.approvals.isEmpty)
        XCTAssertEqual(approvals.auditEvents.count, 1); XCTAssertEqual(approvals.reviewerSettings?.apiKey, "synthetic-reviewer")
        XCTAssertEqual(try coordinator.status(), .ready)
        XCTAssertEqual(try source.encoded(), before)
        XCTAssertFalse(String(describing: source).contains("synthetic"))
        XCTAssertFalse(String(reflecting: source).contains("synthetic"))
        XCTAssertFalse(String(data: try XCTUnwrap(destination.files["meta.json"]), encoding: .utf8)!.contains("synthetic-value"))
    }
    /// 【验收 R1】确认之前只能看旧文件夹里有没有文件名：文件不可读也照样判断，说明没有打开内容；
    /// 不存在是全新安装；符号链接、不是目录等异常必须失败，不能当成空。
    func testPresenceCheckUsesNamesOnlyAndFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-presence-\(UUID())")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("old").path)
                try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        XCTAssertFalse(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: root.appendingPathComponent("missing")))
        let old = root.appendingPathComponent("old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        XCTAssertFalse(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: old))
        try Data().write(to: old.appendingPathComponent(".DS_Store"))
        XCTAssertFalse(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: old), "Finder metadata is not old data")
        let meta = old.appendingPathComponent("meta.json")
        try Data("synthetic-unreadable".utf8).write(to: meta)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: meta.path)
        XCTAssertTrue(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: old), "Presence must not need to open the file")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: old)
        XCTAssertThrowsError(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: link))
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        XCTAssertThrowsError(try IdentityMigrationLegacyCapture.legacyFilesExist(directory: file))
    }

    /// 【验收 R2】确认的是「准备空库」却读到旧数据，或确认「复制」却读到空来源：一个字节都不写。
    func testFirstWriteRefusesASourceOfTheOtherKindThanConfirmed() throws {
        let legacy = try fixture(), empty = IdentityMigrationSource(preferences: Data("{}".utf8))
        XCTAssertTrue(legacy.hasLegacyData)
        XCTAssertFalse(empty.hasLegacyData)
        XCTAssertFalse(IdentityMigrationSource(preferences: Data(#"{"interfaceLanguage":"en"}"#.utf8)).hasLegacyData)
        XCTAssertTrue(IdentityMigrationSource(approvals: legacy.approvals).hasLegacyData, "Old access history is old data")
        for (source, expected) in [(legacy, false), (empty, true)] {
            let destination = Destination()
            XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: destination)
                .migrate(source: source, expectedLegacyData: expected)) {
                XCTAssertEqual($0 as? IdentityMigrationError, .sourceChanged)
            }
            XCTAssertEqual(destination.writeCount, 0); XCTAssertNil(destination.journal)
        }
        for (source, expected) in [(legacy, true), (empty, false)] {
            let destination = Destination(), coordinator = IdentityMigrationCoordinator(destination: destination)
            try coordinator.migrate(source: source, expectedLegacyData: expected)
            XCTAssertEqual(try coordinator.status(), .ready)
        }
    }

    func testEveryPartialWriteRecoversForwardAndReplayHasNoAdditionalEffects() throws {
        let source = try fixture(), complete = Destination()
        try IdentityMigrationCoordinator(destination: complete).migrate(source: source)
        for failure in 1...complete.writeCount {
            let destination = Destination(); destination.failAt = failure
            let first = IdentityMigrationCoordinator(destination: destination)
            XCTAssertThrowsError(try first.migrate(source: source))
            destination.failAt = nil
            let recovered = IdentityMigrationCoordinator(destination: destination)
            if failure == 1 { try recovered.migrate(source: source) } else {
                XCTAssertEqual(try recovered.status(), .pending)
                XCTAssertNotNil(try recovered.recover())
            }
            XCTAssertEqual(try recovered.status(), .ready)
            XCTAssertEqual(destination.items[.values], source.values)
            let count = destination.writeCount
            _ = try recovered.migrate(source: source); _ = try recovered.recover()
            XCTAssertEqual(destination.writeCount, count)
        }
    }
    func testAmbiguousSuccessfulWritesUseReadbackWithoutDuplicateCreate() throws {
        let source = try fixture(), complete = Destination()
        try IdentityMigrationCoordinator(destination: complete).migrate(source: source)
        for failure in 1...complete.writeCount {
            let destination = Destination(); destination.failAt = failure; destination.failAfterWrite = true
            let coordinator = IdentityMigrationCoordinator(destination: destination)
            try coordinator.migrate(source: source)
            XCTAssertEqual(try coordinator.status(), .ready)
            XCTAssertEqual(destination.writeCount, complete.writeCount)
        }
    }
    func testDestinationConflictAndChangedPendingSourceNeverOverwrite() throws {
        let source = try fixture(), destination = Destination()
        destination.items[.values] = Data("different".utf8)
        XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: destination).migrate(source: source))
        XCTAssertEqual(destination.writeCount, 0); XCTAssertNil(destination.journal)
        let pending = Destination(); pending.failAt = 2
        let coordinator = IdentityMigrationCoordinator(destination: pending)
        XCTAssertThrowsError(try coordinator.migrate(source: source))
        let before = pending.journal; var changed = source; changed.preferences = Data("{}".utf8)
        pending.failAt = nil
        XCTAssertThrowsError(try coordinator.migrate(source: changed))
        XCTAssertEqual(pending.journal, before)
        pending.items[.approvals] = Data("third-state".utf8)
        XCTAssertThrowsError(try coordinator.recover())
        XCTAssertEqual(pending.items[.approvals], Data("third-state".utf8))
    }
    func testMalformedHMACUnknownFieldsAndUnsignedMetadataRefuseBeforeWrites() throws {
        let source = try fixture()
        var invalid = source; invalid.integrityKey = Data(repeating: 8, count: 32)
        var unsigned = source
        var meta = try IdentityMigrationCodec.decode(MetaFile.self, from: XCTUnwrap(source.metadata))
        meta.integrity = nil; unsigned.metadata = try IdentityMigrationCodec.encode(meta); unsigned.integrityKey = nil
        var unknown = source
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(source.metadata)) as? [String: Any])
        object["futureRequiredField"] = true; unknown.metadata = try JSONSerialization.data(withJSONObject: object)
        for rejected in [invalid, unsigned, unknown] {
            let destination = Destination()
            XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: destination).migrate(source: rejected))
            XCTAssertEqual(destination.writeCount, 0)
        }
        let approved = Destination()
        try IdentityMigrationCoordinator(destination: approved).migrate(source: unsigned, allowUnsignedMetadata: true)
        XCTAssertEqual(approved.items[.values], unsigned.values)
    }
    func testSourceSamplingAndReadyReceiptFailClosed() throws {
        let source = try fixture(); var reads = 0
        XCTAssertThrowsError(try IdentityMigrationLegacyCapture.stableCapture {
            reads += 1; var copy = source
            if reads == 2 { copy.preferences = Data("{}".utf8) }
            return copy
        })
        let destination = Destination(), coordinator = IdentityMigrationCoordinator(destination: Destination())
        XCTAssertNil(try coordinator.recover())
        try IdentityMigrationCoordinator(destination: destination).migrate(source: source)
        destination.items.removeValue(forKey: .values)
        XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: destination).status())
    }
    func testPreferencesPreserveExplicitNewChoiceAndRejectSecretOrUnknownFields() throws {
        let name = "keykeeper-test-identity-preferences-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name)); defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("zh-Hans", forKey: "interfaceLanguage")
        try IdentityMigrationPreferences.apply(Data(#"{"approvalSoundEnabled":true,"interfaceLanguage":"en"}"#.utf8), to: defaults)
        XCTAssertEqual(defaults.string(forKey: "interfaceLanguage"), "zh-Hans")
        XCTAssertTrue(defaults.bool(forKey: "approvalSoundEnabled"))
        XCTAssertThrowsError(try IdentityMigrationPreferences.decode(Data(#"{"apiKey":"synthetic"}"#.utf8)))
        XCTAssertThrowsError(try IdentityMigrationPreferences.decode(Data(#"{"approvalSoundEnabled":1}"#.utf8)))
    }
    func testPreparedCodecCanonicalAcrossDictionaryOrdersAndFreshVault() throws {
        let prepared = try fixture().prepared(allowUnsignedMetadata: false)
        var reversed = prepared
        reversed.items = Dictionary(uniqueKeysWithValues: prepared.items.sorted { $0.key.rawValue > $1.key.rawValue })
        XCTAssertEqual(try IdentityMigrationCodec.encode(prepared), try IdentityMigrationCodec.encode(reversed))
        _ = try IdentityMigrationCodec.decode(IdentityMigrationPrepared.self, from: IdentityMigrationCodec.encode(prepared))
        let destination = Destination(), coordinator = IdentityMigrationCoordinator(destination: Destination())
        XCTAssertEqual(try coordinator.status(), .required)
        let result = try IdentityMigrationCoordinator(destination: destination).migrate(source: .init())
        XCTAssertEqual(result.credentialCount, 0)
    }
    func testBrowserCookiesAndSecurityPreservedButLegacyGrantsRemoved() throws {
        var source = try fixture()
        let id = UUID().uuidString
        let snapshot = BrowserSessionImport(id: id, origin: "https://example.com", label: "Fixture browser",
            cookies: [.init(name: "fixture", value: "synthetic-cookie", domain: "example.com", hostOnly: true,
                path: "/", secure: true, httpOnly: true, sameSite: "lax", expirationDate: 1)])
        let snap = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot))
        source.browserSessions = try JSONSerialization.data(withJSONObject: ["version": 1,
            "records": [id: ["snapshot": snap, "createdAt": 0, "security": "strict"]],
            "grants": [["id": "old", "sessionId": id, "subjectFingerprint": "fixture", "subjectDisplayName": "Fixture",
                        "duration": ["type": "always"], "createdAt": 0, "consumed": false]]])
        source.browserMarker = true
        let destination = Destination()
        let summary = try IdentityMigrationCoordinator(destination: destination).migrate(source: source)
        XCTAssertEqual(summary.browserSessionCount, 1)
        let browser = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(destination.items[.browserSessions])) as? [String: Any])
        XCTAssertNil(browser["grants"])
        let records = try XCTUnwrap(browser["records"] as? [String: [String: Any]])
        XCTAssertEqual(records[id]?["security"] as? String, "strict")
        let saved = try JSONDecoder().decode(BrowserSessionImport.self, from: JSONSerialization.data(withJSONObject: XCTUnwrap(records[id]?["snapshot"])))
        XCTAssertEqual(saved, snapshot)
        XCTAssertEqual(destination.files["browser-store.created"], Data([1]))
    }
    func testActiveImportBlocksAndTerminalReceiptIsPreserved() throws {
        var source = try fixture()
        let id = String(repeating: "a", count: 64)
        var record = BrowserImportProposalRecord(snapshot: .init(id: id, credentialId: "fixture", fieldName: "api-key", state: .pasteReceived),
            request: nil, callerName: nil, candidate: nil, metadataFingerprint: nil, targetValueFingerprint: nil,
            createdAt: Date(timeIntervalSinceReferenceDate: 0), updatedAt: Date(timeIntervalSinceReferenceDate: 0))
        func bytes() throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": 1, "records": [id: JSONSerialization.jsonObject(with: JSONEncoder().encode(record))]])
        }
        source.proposals = try bytes()
        let rejected = Destination()
        XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: rejected).migrate(source: source)) { error in
            XCTAssertEqual(error as? IdentityMigrationError, .activeImport)
        }
        XCTAssertEqual(rejected.writeCount, 0)
        record.snapshot.state = .committed; source.proposals = try bytes()
        let destination = Destination()
        try IdentityMigrationCoordinator(destination: destination).migrate(source: source)
        XCTAssertEqual(destination.items[.proposals], source.proposals)
        XCTAssertEqual(destination.files["browser-import-proposals.created"], Data([1]))
    }
    func testKnownMissingMarkersAndInlineSecretBlockBeforeWriting() throws {
        var missingBrowser = try fixture(); missingBrowser.browserMarker = true
        var missingProposal = try fixture(); missingProposal.proposalMarker = true
        var inline = try fixture()
        var meta = try IdentityMigrationCodec.decode(MetaFile.self, from: XCTUnwrap(inline.metadata))
        meta.credentials["fixture"]?.fields["api-key"]?.value = "synthetic-inline"
        meta.integrity = try MetaIntegrity.mac(for: meta, key: XCTUnwrap(inline.integrityKey))
        inline.metadata = try IdentityMigrationCodec.encode(meta)
        for rejected in [missingBrowser, missingProposal, inline] {
            let destination = Destination()
            XCTAssertThrowsError(try IdentityMigrationCoordinator(destination: destination).migrate(source: rejected))
            XCTAssertEqual(destination.writeCount, 0)
        }
    }
    func testSyntheticSeamRequiresCompleteDedicatedTriple() throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("keykeeper-migration-" + id)
        let env = ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.migration." + id,
                   "KEYKEEPER_DATA_DIR": directory.path, "KEYKEEPER_TEST_SOCKET": "/tmp/keykeeper-test-migration-" + id + ".sock"]
        XCTAssertNil(try IdentityMigrationFixture.resolve(environment: [:]))
        XCTAssertNotNil(try IdentityMigrationFixture.resolve(environment: env))
        for key in env.keys {
            var partial = env; partial.removeValue(forKey: key)
            XCTAssertThrowsError(try IdentityMigrationFixture.resolve(environment: partial))
        }
        var production = env; production["KEYKEEPER_DATA_DIR"] = StorageIdentity.legacy.directory.path
        XCTAssertThrowsError(try IdentityMigrationFixture.resolve(environment: production))
        production = env; production["KEYKEEPER_KEYCHAIN_SERVICE"] = "com.keykeeper.credentials"
        XCTAssertThrowsError(try IdentityMigrationFixture.resolve(environment: production))
    }
    func testUnsupportedLocalFilesBlockInsteadOfDisappearing() throws {
        XCTAssertNoThrow(try IdentityMigrationLegacyCapture.validateSourceFileNames(["meta.json", "meta.json.lock", "browser-store.created",
            "grants.json.migrated-2026-09-14"]))
        for unsupported in ["future-state.json", "provider-auth.json", "service-grants.json", "grants.json", "subdirectory"] {
            XCTAssertThrowsError(try IdentityMigrationLegacyCapture.validateSourceFileNames(["meta.json", unsupported]))
        }
    }
    func testFilePublicationIsCreateOnlyAndRejectsSymlinks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-migration-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("meta.json")
        try IdentityMigrationFiles.create(Data("first".utf8), at: file)
        XCTAssertThrowsError(try IdentityMigrationFiles.create(Data("replacement".utf8), at: file))
        XCTAssertEqual(try IdentityMigrationFiles.read(file), Data("first".utf8))
        let symbolic = directory.appendingPathComponent("symbolic.json")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: file)
        XCTAssertThrowsError(try IdentityMigrationFiles.read(symbolic))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["meta.json", "symbolic.json"])
    }

}
