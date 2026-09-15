import XCTest
@testable import KeyKeeperApp
import KeyKeeperCore
import CryptoKit

@MainActor final class CredentialFileSourceTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-file-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        file = directory.appendingPathComponent("fixture.json")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testPythonSourceIsTextAndOpenedWithoutParsingUntilRead() throws {
        let sourceFile = directory.appendingPathComponent("fixture.py")
        try Data("invalid Python !!!".utf8).write(to: sourceFile)
        let invalid = try CredentialFileSource(filePath: sourceFile.path, pythonSymbol: "ADMIN_KEY")
        XCTAssertNil(invalid.fileFormat)
        XCTAssertEqual(invalid.pythonSymbol, "ADMIN_KEY")
        XCTAssertThrowsError(try invalid.readText())
        let bytes = Data("ADMIN_KEY = os.getenv('ADMIN_KEY', 'synthetic-value')".utf8)
        try bytes.write(to: sourceFile)
        let source = try CredentialFileSource(filePath: sourceFile.path, pythonSymbol: "ADMIN_KEY")
        XCTAssertEqual(try source.readText(), "synthetic-value")
        source.clearIfUnchanged(since: 0)
        XCTAssertEqual(try Data(contentsOf: sourceFile), bytes)
        try bytes.write(to: sourceFile, options: .atomic)
        XCTAssertThrowsError(try source.readText()) { XCTAssertEqual($0 as? ClipboardSaveError, .fileChanged) }
    }

    func testBoundedReadAndOriginalIsNeverRemoved() throws {
        let bytes = Data("{\"type\":\"service_account\",\"client_email\":\"fixture@example.invalid\",\"private_key\":\"synthetic-only\"}\n".utf8)
        try bytes.write(to: file)
        let source = try CredentialFileSource(filePath: file.path)
        XCTAssertEqual(source.fileFormat, .serviceAccountJSON)
        XCTAssertEqual(try source.readText(), String(data: bytes, encoding: .utf8))
        source.clearIfUnchanged(since: source.changeCount)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testAppleProviderSelectsP8ParserInsteadOfGoogleJSONParser() throws {
        let document = P256.Signing.PrivateKey().pemRepresentation + "\n"
        let keyFile = directory.appendingPathComponent("AuthKey_SYNTHETIC.p8")
        try Data(document.utf8).write(to: keyFile)
        let source = try CredentialFileSource(filePath: keyFile.path, format: .applePrivateKeyP8)
        XCTAssertEqual(source.fileFormat, .applePrivateKeyP8)
        XCTAssertEqual(try source.readText(), document)
    }
    func testReplacementInPlaceModificationSymlinkAndOversizeFailClosed() throws {
        try Data("synthetic".utf8).write(to: file)
        let source = try CredentialFileSource(filePath: file.path)
        try Data("changed".utf8).write(to: file, options: .atomic)
        XCTAssertNotEqual(source.changeCount, 0)
        XCTAssertThrowsError(try source.readText())
        let inPlace = try CredentialFileSource(filePath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("changed-in-place".utf8)); try handle.close()
        XCTAssertThrowsError(try inPlace.readText())
        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try CredentialFileSource(filePath: link.path))
        XCTAssertThrowsError(try CredentialFileSource(filePath: directory.path))
        try Data(repeating: 65, count: 65_537).write(to: file)
        XCTAssertThrowsError(try CredentialFileSource(filePath: file.path))
    }
}
