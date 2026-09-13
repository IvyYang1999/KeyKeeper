import ArgumentParser
import KeyKeeperCore
import Darwin

struct SaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract:
        "Save clipboard text, a credential file or a Python source literal with one-time approval. Never prints or overwrites a key.")
    @Option(name: [.customShort("c"), .long], help: "Exact credential ID.")
    var credential: String
    @Option(help: "Secret field name.") var field: String
    @Flag(help: "Read the system clipboard inside the App only after approval.")
    var fromClipboard = false
    @Flag(help: "Print a single-use local receiver URL for paste; keep this command running until confirmation. Do not mix clipboard transports.")
    var fromBrowser = false
    @Option(help: "Absolute path to a service-account JSON file (up to 64 KiB). App reads it after approval; original is retained.")
    var fromFile: String?
    @Option(help: "Absolute path to an owned UTF-8 Python file (up to 1 MiB). App parses it after approval without executing it.")
    var fromSource: String?
    @Option(help: "Exact top-level Python symbol for --from-source. Accepts a string literal or os.getenv/os.environ.get string default only.")
    var pythonSymbol: String?
    @Flag(help: "Create a new strict credential; refuses an existing ID.")
    var create = false
    @Option(help: "What the value should look like: base64[:BYTES], hex[:BYTES], bytes:N or chars:N. Refuses the save if it does not match, before anything is written.")
    var expect: String?

    mutating func validate() throws {
        guard [fromClipboard, fromBrowser, fromFile != nil, fromSource != nil].filter({ $0 }).count == 1 else {
            throw ValidationError("Choose exactly one: --from-clipboard, --from-browser, --from-file or --from-source. Never put a key in command arguments.")
        }
        guard (fromSource != nil) == (pythonSymbol != nil) else {
            throw ValidationError("--from-source requires --python-symbol; --python-symbol is not valid with other sources.")
        }
        try request.validate()
        if let fromFile { try FileImportRequest(target: request, filePath: fromFile).validate() }
        if let fromSource, let pythonSymbol {
            try SourceImportRequest(target: request, filePath: fromSource, pythonSymbol: pythonSymbol).validate()
        }
    }
    var request: ClipboardSaveRequest {
        .init(credentialId: credential, fieldName: field, create: create, expect: expect)
    }

    /// What went in, without saying what it is. The clipboard is a shared channel and a save
    /// that only ever prints "Saved." cannot tell you it stored the wrong thing.
    static func storedSummary(_ shape: ValueShape) -> String {
        var parts = ["\(shape.characters) characters"]
        if shape.bytes != shape.characters { parts.append("\(shape.bytes) bytes") }
        if let base64 = shape.base64DecodedBytes { parts.append("Base64 (\(base64) bytes)") }
        else if let hex = shape.hexDecodedBytes { parts.append("hex (\(hex) bytes)") }
        if shape.lines > 1 { parts.append("\(shape.lines) lines") }
        if shape.hasNonASCII { parts.append("non-ASCII") }
        return parts.joined(separator: ", ")
    }
    mutating func run() throws {
        if let fromSource, let pythonSymbol {
            let result = try IPCClient.requestSourceImport(.init(target: request, filePath: fromSource, pythonSymbol: pythonSymbol))
            guard result.success else { throw CommandFailure(result.errorCode?.localizedDescription ?? "Save failed.") }
            print("Saved source candidate. Original retained. Runtime/provider access is not verified. No read permission was granted.")
            return
        }
        if let fromFile {
            let result = try IPCClient.requestFileImport(.init(target: request, filePath: fromFile))
            guard result.success else { throw CommandFailure(result.errorCode?.localizedDescription ?? "Save failed.") }
            print("Saved credential file. Original file retained. No read permission was granted.")
            return
        }
        let result = try IPCClient.requestClipboardSave(request, fromBrowser: fromBrowser) { url in
            print("Open this single-use URL, paste through the SAME clipboard transport used to copy, then confirm in KeyKeeper. Ordinary Chrome: native Copy + native Paste; do not mix browser-tool and system clipboards:")
            print(url); fflush(stdout)
        }
        guard result.success else {
            var message = result.errorCode?.localizedDescription ?? "Save failed."
            // On a shape refusal the App reports what was there instead: that is the fastest
            // way to see that the clipboard was overwritten between the copy and the save.
            if let shape = result.shape { message += " Clipboard holds: \(Self.storedSummary(shape))." }
            throw CommandFailure(message)
        }
        var note = fromBrowser ? "Saved. Browser clipboard was not cleared. No read permission was granted." : "Saved. Clipboard cleared if unchanged. No read permission was granted."
        if let shape = result.shape { note += " Stored: \(Self.storedSummary(shape))." }
        print(note)
    }
}
