import ArgumentParser
import Foundation
import KeyKeeperCore

struct ProposalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "proposal",
        abstract: "Inspect or reopen a browser import without resending the secret",
        subcommands: [Status.self, Open.self]
    )

    struct Status: ParsableCommand {
        @Argument(help: "Proposal ID printed by keykeeper save --from-browser.") var id: String
        @Flag(help: "Print the metadata-only proposal state as JSON.") var json = false
        func run() throws { try ProposalCommand.printProposal(.init(id: id, action: .status), json: json) }
    }

    struct Open: ParsableCommand {
        @Argument(help: "Proposal ID printed by keykeeper save --from-browser.") var id: String
        @Flag(help: "Print the metadata-only proposal state as JSON.") var json = false
        func run() throws { try ProposalCommand.printProposal(.init(id: id, action: .open), json: json) }
    }

    fileprivate static func printProposal(_ request: BrowserImportProposalRequest, json: Bool) throws {
        let proposal = try IPCClient.requestBrowserImportProposal(request)
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(proposal), as: UTF8.self))
            return
        }
        print("Proposal: \(proposal.id)")
        print("Target: \(proposal.credentialId) · \(proposal.fieldName)")
        print("State: \(proposal.state.rawValue)")
        if let deadline = proposal.deadline { print("Deadline: \(ISO8601DateFormatter().string(from: deadline))") }
        if let next = proposal.nextAction { print("Next: \(next)") }
        if let error = proposal.errorCode { print("Result: \(error.localizedDescription)") }
    }
}
