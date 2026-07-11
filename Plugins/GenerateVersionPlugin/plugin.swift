import PackagePlugin

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
            .prebuildCommand(
                displayName: "Generating KeyKeeper build version",
                executable: generator.path,
                arguments: [context.package.directory.string, output.string],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
