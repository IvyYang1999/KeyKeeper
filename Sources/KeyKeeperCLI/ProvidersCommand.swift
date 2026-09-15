import ArgumentParser
import Foundation
import KeyKeeperCore

/// The provider templates, for an agent that has to get a key it does not have yet.
struct ProvidersCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "Provider templates: where a key is created, which steps only the person can do, the smallest useful permission, and how KeyKeeper verifies it.",
        subcommands: [List.self, Show.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the templates")
        func run() { print(ProvidersCommand.listText()) }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "One template as JSON")
        @Argument(help: "Template id or alias (openai, claude, …)") var provider: String
        func run() throws {
            guard let text = ProvidersCommand.showText(provider) else {
                throw CommandFailure("No template for '\(provider)'. Run `keykeeper providers` to see them.")
            }
            print(text)
        }
    }

    static func listText() -> String {
        ProviderCatalog.all.map { template in
            let fields = template.fields.map { field in
                let destination = field.environmentNames.isEmpty ? "" : " → " + field.environmentNames.joined(separator: " / ")
                let kind: String
                switch field.kind {
                case .secretText: kind = "secret text"
                case .secretFile: kind = "credential file"
                case .publicText: kind = "non-secret"
                case .localIdentity: kind = "local identity"
                }
                return "\(field.name)\(destination) [\(kind)]"
            }.joined(separator: ", ")
            let fieldLabel = template.fields.count == 1 ? "field" : "\(template.fields.count) fields"
            return "\(template.id) | \(template.name) | \(fieldLabel): \(fields)"
                + (template.aliases.isEmpty ? "" : " | also: \(template.aliases.joined(separator: ", "))")
                + (template.validation == nil ? "" : " | verified after saving")
        }.joined(separator: "\n")
    }

    static func showText(_ idOrAlias: String) -> String? {
        guard let template = ProviderCatalog.find(idOrAlias) else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(template) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
