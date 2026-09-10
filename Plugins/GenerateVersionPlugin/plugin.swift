import PackagePlugin
import Foundation

@main
struct GenerateVersionPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        let generator = try context.tool(named: "VersionGenerator")
        let outputDirectory = context.pluginWorkDirectory.appending("GeneratedSources")
        let output = outputDirectory.appending("BuildVersion.generated.swift")

        return [
            .buildCommand(
                displayName: "Generating KeyKeeper build version",
                executable: generator.path,
                arguments: [context.package.directory.string, output.string],
                environment: ["KEYKEEPER_BUILD_VERSION": ProcessInfo.processInfo.environment["KEYKEEPER_BUILD_VERSION"] ?? ""],
                inputFiles: versionInputs(in: context.package.directory),
                outputFiles: [output]
            )
        ]
    }

    /// A build command supports a source-built generator. Track the Git inputs so
    /// cached generated sources cannot keep a previous commit's version label.
    private func versionInputs(in directory: Path) -> [Path] {
        let root = URL(fileURLWithPath: directory.string, isDirectory: true)
        let dotGit = root.appendingPathComponent(".git")
        var inputs = [directory.appending("Package.swift")]
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return inputs }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGit
        } else {
            inputs.append(Path(dotGit.path))
            guard let pointer = try? String(contentsOf: dotGit, encoding: .utf8), pointer.hasPrefix("gitdir: ") else { return inputs }
            let location = pointer.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDirectory = URL(fileURLWithPath: location, relativeTo: root).standardizedFileURL
        }
        var candidates = [gitDirectory.appendingPathComponent("HEAD"), gitDirectory.appendingPathComponent("packed-refs")]
        if let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8), head.hasPrefix("ref: ") {
            let reference = head.dropFirst("ref: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(gitDirectory.appendingPathComponent(reference))
        }
        inputs += candidates.filter { FileManager.default.fileExists(atPath: $0.path) }.map { Path($0.path) }
        return inputs
    }
}
