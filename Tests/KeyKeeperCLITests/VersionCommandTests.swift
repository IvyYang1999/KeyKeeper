import Foundation
import XCTest

final class VersionCommandTests: XCTestCase {
    func testVersionFlagPrintsComparableVersionAndExitsSuccessfully() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("keykeeper")

        let output = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--version"]
        process.standardOutput = output
        process.standardError = output

        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let version = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertEqual(process.terminationStatus, 0, "output: \(version)")
        XCTAssertFalse(version.isEmpty)
        XCTAssertTrue(version.contains("keykeeper"), "version must identify the deployed artifact")
        let fields = version.split(separator: " ", omittingEmptySubsequences: true)
        XCTAssertEqual(fields.count, 2, "version must contain a comparable identifier")
        XCTAssertFalse(fields[1].isEmpty)
    }

    func testVersionGeneratorFallsBackToUnknownWithoutGitMetadata() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = temporaryDirectory.appendingPathComponent("BuildVersion.generated.swift")
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let standardError = Pipe()
        let process = Process()
        process.executableURL = packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("VersionGenerator")
        process.arguments = [temporaryDirectory.path, output.path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "KEYKEEPER_BUILD_VERSION")
        process.environment = environment
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        let errorOutput = String(
            decoding: standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        XCTAssertEqual(process.terminationStatus, 0, errorOutput)
        let generatedSource = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(generatedSource.contains("keykeeper unknown"))
    }

    func testDeployVerifierRejectsStaleTarget() throws {
        let fixture = try DeployVerifierFixture()
        defer { fixture.remove() }

        try fixture.writeExecutable(named: "built", version: "keykeeper abc123")
        try fixture.writeExecutable(named: "installed", version: "keykeeper stale000")

        let result = try fixture.runVerifier(expected: "keykeeper abc123")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("ERROR"), result.stderr)
        XCTAssertTrue(result.stderr.contains("stale000"), result.stderr)
        XCTAssertTrue(result.stderr.contains("abc123"), result.stderr)
    }

    func testDeployVerifierAcceptsMatchingTargetSilently() throws {
        let fixture = try DeployVerifierFixture()
        defer { fixture.remove() }

        try fixture.writeExecutable(named: "built", version: "keykeeper abc123")
        try fixture.writeExecutable(named: "installed", version: "keykeeper abc123")

        let result = try fixture.runVerifier(expected: "keykeeper abc123")

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "")
    }
}

private struct DeployVerifierFixture {
    let directory: URL
    let packageRoot: URL

    init() throws {
        packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeExecutable(named name: String, version: String) throws {
        let url = directory.appendingPathComponent(name)
        let script = "#!/bin/sh\nprintf '%s\\n' '\(version)'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    func runVerifier(expected: String) throws -> (status: Int32, stdout: String, stderr: String) {
        let standardOutput = Pipe()
        let standardError = Pipe()
        let process = Process()
        process.executableURL = packageRoot
            .appendingPathComponent("scripts")
            .appendingPathComponent("verify-cli-deploy.sh")
        process.arguments = [
            directory.appendingPathComponent("built").path,
            expected,
            directory.appendingPathComponent("installed").path,
        ]
        process.standardOutput = standardOutput
        process.standardError = standardError

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(decoding: standardOutput.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
