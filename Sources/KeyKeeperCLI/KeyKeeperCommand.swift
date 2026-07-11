import ArgumentParser

@main
struct KeyKeeperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keykeeper",
        abstract: "Secure API key management for AI coding tools",
        version: BuildVersion.identifier,
        subcommands: [
            ListCommand.self,
            GetCommand.self,
            MetaCommand.self,
            RunCommand.self,
            GrantsCommand.self,
            RequestsCommand.self,
        ]
    )
}
