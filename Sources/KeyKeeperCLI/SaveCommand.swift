import ArgumentParser
import KeyKeeperCore
import Darwin

struct SaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract:
        "Save clipboard text or a service-account JSON file with one-time approval. Never prints or overwrites a key.")
    @Option(name: [.customShort("c"), .long], help: "Exact credential ID.")
    var credential: String
    @Option(help: "Secret field name.") var field: String
    @Flag(help: "Read the system clipboard inside the App only after approval.")
    var fromClipboard = false
    @Flag(help: "Print a single-use local receiver URL for browser Paste; keep this command running until confirmation.")
    var fromBrowser = false
    @Option(help: "Absolute path to a service-account JSON file (up to 64 KiB). App reads it after approval; original is retained.")
    var fromFile: String?
    @Flag(help: "Create a new strict credential; refuses an existing ID.")
    var create = false

    mutating func validate() throws {
        guard [fromClipboard, fromBrowser, fromFile != nil].filter({ $0 }).count == 1 else {
            throw ValidationError("Choose exactly one: --from-clipboard, --from-browser or --from-file <absolute-path>. Never put a key in command arguments.")
        }
        try request.validate()
        if let fromFile { try FileImportRequest(target: request, filePath: fromFile).validate() }
    }
    var request: ClipboardSaveRequest {
        .init(credentialId: credential, fieldName: field, create: create)
    }
    mutating func run() throws {
        if let fromFile {
            let result = try IPCClient.requestFileImport(.init(target: request, filePath: fromFile))
            guard result.success else { throw CommandFailure(result.errorCode?.localizedDescription ?? "Save failed.") }
            print("Saved credential file. Original file retained. No read permission was granted.")
            return
        }
        let result = try IPCClient.requestClipboardSave(request, fromBrowser: fromBrowser) { url in
            print("Open this single-use URL in the same browser session, paste, then confirm in KeyKeeper:")
            print(url); fflush(stdout)
        }
        guard result.success else { throw CommandFailure(result.errorCode?.localizedDescription ?? "Save failed.") }
        print(fromBrowser ? "Saved. Browser clipboard was not cleared. No read permission was granted." : "Saved. Clipboard cleared if unchanged. No read permission was granted.")
    }
}
