import ArgumentParser
import KeyKeeperCore

struct SaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract:
        "Ask the App to save clipboard text after one-time approval. Never prints or overwrites a key.")
    @Option(name: [.customShort("c"), .long], help: "Exact credential ID.")
    var credential: String
    @Option(help: "Secret field name.") var field: String
    @Flag(help: "Read clipboard inside the App only after approval (required).")
    var fromClipboard = false
    @Flag(help: "Create a new strict credential; refuses an existing ID.")
    var create = false

    mutating func validate() throws {
        guard fromClipboard else { throw ValidationError("--from-clipboard is required. Never put a key in command arguments.") }
        try request.validate()
    }
    var request: ClipboardSaveRequest {
        .init(credentialId: credential, fieldName: field, create: create)
    }
    mutating func run() throws {
        let result = try IPCClient.requestClipboardSave(request)
        guard result.success else { throw CommandFailure(result.errorCode?.localizedDescription ?? "Save failed.") }
        print("Saved. Clipboard cleared if unchanged. No read permission was granted.")
    }
}
