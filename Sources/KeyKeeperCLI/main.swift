import ArgumentParser

@main
struct KeyKeeperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "keykeeper",
        abstract: "Secure API key management for AI coding tools"
    )
}
