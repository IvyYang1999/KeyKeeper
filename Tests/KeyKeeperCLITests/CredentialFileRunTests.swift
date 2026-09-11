import Darwin
import XCTest
import KeyKeeperCore
@testable import KeyKeeperCLI

final class CredentialFileRunTests: XCTestCase {
    private func makeLease() throws -> CredentialFileLease {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try CredentialFileLease(executable: repo.appendingPathComponent(".build/debug/keykeeper"))
    }
    private func fixture() -> Credential {
        .init(label: "fixture", notes: "", links: [],
              fields: ["json": .init(secret: true, fileFormat: .serviceAccountJSON), "key": .init(secret: true)],
              security: .strict, created: "", updated: "")
    }
    func testFilesRequireExplicitUnambiguousMappingBeforeReadingSecrets() throws {
        let meta = MetaFile(credentials: ["fixture": fixture()])
        let plan = try FileInjectionPlan(credentials: ["fixture"], mappings: ["fixture:json=GOOGLE_APPLICATION_CREDENTIALS"], prefix: "", meta: meta)
        XCTAssertEqual(plan.environmentName(credential: "fixture", field: "json"), "GOOGLE_APPLICATION_CREDENTIALS")
        for mappings in [[], ["fixture:json=KEY"], ["other:json=FILE"], ["fixture:key=FILE"],
                         ["fixture:json=PATH"], ["fixture:json=FILE", "fixture:json=SECOND"]] {
            XCTAssertThrowsError(try FileInjectionPlan(credentials: ["fixture"], mappings: mappings, prefix: "", meta: meta))
        }
        XCTAssertThrowsError(try RunCommand.parse(["-c", "fixture", "--file", "fixture:json=FILE", "--tty", "--", "true"]))
    }
    func testPrivateLeasePreservesBytesAndRemovesFilesOnClose() throws {
        let lease = try makeLease()
        let directory = lease.directory
        let value = "synthetic-file-payload"
        let filename = try lease.write(Data(value.utf8))
        var dirInfo = stat(); var fileInfo = stat()
        XCTAssertEqual(lstat(directory.path, &dirInfo), 0)
        XCTAssertEqual(lstat(filename, &fileInfo), 0)
        XCTAssertEqual(dirInfo.st_mode & 0o777, 0o700)
        XCTAssertEqual(fileInfo.st_mode & 0o777, 0o600)
        XCTAssertEqual(try String(contentsOfFile: filename), value)
        try CredentialFileLease.sweepStale()
        XCTAssertTrue(FileManager.default.fileExists(atPath: filename), "An active concurrent lease must survive cleanup")
        lease.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
    func testClosingLivenessChannelModelsParentCrash() throws {
        let lease = try makeLease()
        let filename = try lease.write(Data("synthetic".utf8))
        lease.closeLivenessChannel()
        let deadline = Date().addingTimeInterval(3)
        while FileManager.default.fileExists(atPath: filename), Date() < deadline { usleep(10_000) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: filename))
        lease.close()
    }
    func testStaleLeaseAndUnexpectedSiblingCleanupAreBounded() throws {
        let root = try CredentialFileLease.root()
        let directory = root.appendingPathComponent("lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let marker = directory.appendingPathComponent("lock")
        FileManager.default.createFile(atPath: marker.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        try Data("synthetic-stale".utf8).write(to: directory.appendingPathComponent("credential-0.json"))
        let unrelated = directory.appendingPathComponent("unrelated.txt")
        try Data("preserve".utf8).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CredentialFileLease.sweepStale()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("credential-0.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
    func testFailedGuardLaunchLeavesNoSecretAndFileCountIsBounded() throws {
        XCTAssertThrowsError(try CredentialFileLease(executable: URL(fileURLWithPath: "/nonexistent-keykeeper-fixture")))
        let lease = try makeLease()
        defer { lease.close() }
        for _ in 0..<32 { _ = try lease.write(Data("synthetic".utf8)) }
        XCTAssertThrowsError(try lease.write(Data("extra".utf8)))
        XCTAssertThrowsError(try lease.write(Data(repeating: 65, count: 65_537)))
    }
    func testFileRedactionIncludesIndividualJSONValues() {
        let document = "{\"type\":\"service_account\",\"client_email\":\"fixture@example.invalid\",\"private_key\":\"synthetic-line-one\\nsynthetic-line-two\"}"
        let patterns = CredentialFileFormat.serviceAccountJSON.redactionValues(for: document)
        var matcher = OutputRedactionMatcher(secrets: patterns)
        let output = matcher.process(Data("synthetic-line-one".utf8)) + matcher.finish()
        XCTAssertEqual(String(data: output, encoding: .utf8), "[REDACTED]")
    }
}
