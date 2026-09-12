import ArgumentParser
import Foundation
import KeyKeeperCore

/// Let people and agents tidy names without a prompt. Values and security never change here,
/// and every earlier group ID and field name keeps working.
struct EditCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Rename a credential's group ID or fields, or change its title, notes and field display names.",
        discussion: """
        Titles, notes and display names are free text for people and agents. The group ID \
        (what -c takes) and field names (which become environment variables) must be plain: \
        letters, digits, '-', '_' or '.'. Old group IDs and field names keep working forever, \
        and `run` still sets the old variable names too. Values and security levels never change. \
        No prompt is shown; tell the user what you changed.

        Examples:
          keykeeper edit 百度千帆 --group-id baidu-qianfan --rename-field cc=api-key
          keykeeper edit openai --field-label "api-key=Project key (billing: team)" --notes "Use for evals only"
        """
    )

    @Argument(help: "Current or earlier group ID.")
    var groupId: String

    @Option(name: .customLong("group-id"), help: "New group ID.")
    var newGroupId: String?

    @Option(help: "New title shown to people.")
    var title: String?

    @Option(help: "New notes (replaces the old notes).")
    var notes: String?

    @Option(name: .customLong("rename-field"), help: "old=new field name. Repeatable.")
    var renameField: [String] = []

    @Option(name: .customLong("field-label"), help: "field=Display name. Repeatable; an empty name clears it.")
    var fieldLabel: [String] = []

    func request() throws -> MetadataEditRequest {
        let edit = MetadataEdit(newGroupId: newGroupId, title: title, notes: notes,
                                fieldRenames: try Self.pairs(renameField, option: "--rename-field"),
                                fieldDisplayNames: try Self.pairs(fieldLabel, option: "--field-label"))
        guard edit != MetadataEdit() else {
            throw ValidationError("Nothing to change. Pass --group-id, --title, --notes, --rename-field or --field-label.")
        }
        return MetadataEditRequest(groupId: groupId, edit: edit)
    }

    static func pairs(_ values: [String], option: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for value in values {
            guard let equals = value.firstIndex(of: "="), equals != value.startIndex else {
                throw ValidationError("\(option) takes name=value, got '\(value)'.")
            }
            result[String(value[..<equals])] = String(value[value.index(after: equals)...])
        }
        return result
    }

    static func report(_ response: MetadataEditResponse) -> String {
        var lines = ["Updated \(response.groupId ?? "credential"):"]
        lines += response.changes.map { "- \($0.summary)" }
        lines.append("Values and security are unchanged. Tell the user what you changed.")
        return lines.joined(separator: "\n")
    }

    func run() throws {
        let response = try IPCClient.requestMetadataEdit(try request())
        guard response.success else {
            throw CommandFailure(response.error ?? "The edit was not applied.")
        }
        print(Self.report(response))
    }
}
