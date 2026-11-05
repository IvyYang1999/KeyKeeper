import Foundation
import XCTest

final class VersionPluginBuildTests: XCTestCase {
    // 【曾经的 bug】SwiftPM rejects a source-built executable in a prebuild command.
    // Exercise the real plugin and compiler, including incremental version invalidation.
    func testPluginBuildsAndRefreshesVersionAfterReferenceAndEnvironmentChanges() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("keykeeper-version-build-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }

        func write(_ text: String, to relativePath: String) throws {
            let destination = fixture.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }
        try write("""
        // swift-tools-version: 5.9
        import PackageDescription
        let package = Package(name: "VersionFixture", targets: [
            .executableTarget(name: "probe", plugins: ["GenerateVersionPlugin"]),
            .executableTarget(name: "VersionGenerator", path: "Tools/VersionGenerator"),
            .plugin(name: "GenerateVersionPlugin", capability: .buildTool(), dependencies: ["VersionGenerator"])
        ])
        """, to: "Package.swift")
        try write("print(BuildVersion.identifier)", to: "Sources/probe/main.swift")
        for relativePath in ["Plugins/GenerateVersionPlugin/plugin.swift", "Tools/VersionGenerator/main.swift"] {
            try write(String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8), to: relativePath)
        }
        try write("ref: refs/heads/fixture\n", to: ".git/HEAD")

        func run(_ executable: URL, _ arguments: [String], override: String?) throws -> String {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = fixture
            var environment = ProcessInfo.processInfo.environment
            environment["KEYKEEPER_BUILD_VERSION"] = override
            process.environment = environment
            let log = fixture.appendingPathComponent("process.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            defer { try? output.close() }
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning {
                process.terminate()
                throw NSError(domain: "VersionPluginBuildTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture build timed out"])
            }
            process.waitUntilExit()
            let text = try String(contentsOf: log, encoding: .utf8)
            XCTAssertEqual(process.terminationStatus, 0, text)
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        for (reference, override, expected) in [
            ("a", nil, "aaaaaaaaaaaa"),
            ("b", nil, "bbbbbbbbbbbb"),
            ("b", "synthetic-one", "synthetic-one"),
            ("b", "synthetic-two", "synthetic-two"),
            ("b", nil, "bbbbbbbbbbbb")
        ] as [(String, String?, String)] {
            try write(String(repeating: reference, count: 40) + "\n", to: ".git/refs/heads/fixture")
            _ = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift", "build", "--disable-keychain", "--product", "probe"], override: override)
            let actual = try run(fixture.appendingPathComponent(".build/debug/probe"), [], override: nil)
            XCTAssertEqual(actual, "keykeeper \(expected)")
        }

        // 【曾经的 bug】A linked worktree (`.git` is a `gitdir:` file) keeps branch refs and
        // packed-refs in the shared repository; every worktree build used to say "unknown".
        try FileManager.default.removeItem(at: fixture.appendingPathComponent(".git"))
        let worktreeGit = fixture.appendingPathComponent("shared.git/worktrees/wt")
        try write("gitdir: \(worktreeGit.path)\n", to: ".git")
        try write("ref: refs/heads/wt-branch\n", to: "shared.git/worktrees/wt/HEAD")
        try write("../..\n", to: "shared.git/worktrees/wt/commondir")
        try write(String(repeating: "c", count: 40) + "\n", to: "shared.git/refs/heads/wt-branch")
        _ = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift", "build", "--disable-keychain", "--product", "probe"], override: nil)
        XCTAssertEqual(try run(fixture.appendingPathComponent(".build/debug/probe"), [], override: nil),
                       "keykeeper \(String(repeating: "c", count: 12))")
        try FileManager.default.removeItem(at: fixture.appendingPathComponent("shared.git/refs/heads/wt-branch"))
        try write("# pack-refs with: peeled fully-peeled sorted\n\(String(repeating: "d", count: 40)) refs/heads/wt-branch\n",
                  to: "shared.git/packed-refs")
        _ = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["swift", "build", "--disable-keychain", "--product", "probe"], override: nil)
        XCTAssertEqual(try run(fixture.appendingPathComponent(".build/debug/probe"), [], override: nil),
                       "keykeeper \(String(repeating: "d", count: 12))")
    }
}
