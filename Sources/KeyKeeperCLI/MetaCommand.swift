import ArgumentParser
import Foundation
import KeyKeeperCore

struct MetaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "Show credential metadata as JSON (no secret values)"
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        guard let cred = meta.credentials[credentialId] else {
            throw ValidationError("Credential '\(credentialId)' not found")
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(cred)
        print(String(data: data, encoding: .utf8)!)
    }
}
