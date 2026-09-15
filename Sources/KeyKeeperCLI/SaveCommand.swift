import ArgumentParser
import Foundation
import KeyKeeperCore
import Darwin

struct SaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "save", abstract:
        "Save without printing a key. Existing values are protected unless --replace is explicitly requested and confirmed.")
    @Option(name: [.customShort("c"), .long], help: "Exact credential ID. Optional with --provider (defaults to the template's id).")
    var credential: String?
    @Option(help: "Secret field name. Optional with --provider (defaults to the template's field).") var field: String?
    @Option(help: "A provider template (see `keykeeper providers`): fills in the credential ID and field name, checks the key's shape before saving, and has KeyKeeper verify the saved key with a read-only request. The value never reaches you.")
    var provider: String?
    @Flag(help: "Read the system clipboard inside the App only after approval.")
    var fromClipboard = false
    @Flag(help: "Print a single-use local receiver URL for paste; keep this command running until confirmation. Do not mix clipboard transports.")
    var fromBrowser = false
    @Option(help: "Absolute path to a supported credential file (up to 64 KiB). With --provider, the template chooses its exact file type. App reads it after approval; original is retained.")
    var fromFile: String?
    @Option(help: "Absolute path to an owned UTF-8 Python file (up to 1 MiB). App parses it after approval without executing it.")
    var fromSource: String?
    @Option(help: "Exact top-level Python symbol for --from-source. Accepts a string literal or os.getenv/os.environ.get string default only.")
    var pythonSymbol: String?
    @Flag(help: "Create a new credential (strict unless --security standard); refuses an existing ID.")
    var create = false
    @Option(help: "What the value should look like: base64[:BYTES], hex[:BYTES], bytes:N or chars:N. Refuses the save if it does not match, before anything is written.")
    var expect: String?
    @Flag(help: .hidden)   // 0.3.3 needed it; the current clipboard is now always what is saved.
    var useCurrentClipboard = false
    @Flag(name: .customLong("replace"), help: "Replace one existing text field after explicit confirmation. Requires --from-clipboard and --expect; keeps existing permissions.")
    var replaceExisting = false
    @Option(name: .customLong("expect-ed25519-public-key"), help: "Expected PUBLIC key in Base64; derive and match before saving a base64:32 private seed. Never pass a private key here.")
    var expectedEd25519PublicKey: String?
    @Option(help: "With --create: suggest how the new credential is protected. strict asks every time (the default); standard lets background callers use it after a one-time approval each. The person sees the suggestion and approves or rejects the save.")
    var security: SecurityLevel?
    @Option(help: "With --create: the last day the key works at its provider, YYYY-MM-DD. Shown to the person before saving.")
    var expires: String?
    @Option(help: "With --create: what this key is for, in one line. Required with --security standard. The person reads it, and later requests are judged against it.")
    var purpose: String?
    @Option(name: .customLong("expected-caller"), help: "With --create: who is expected to use it (\"the nightly cron\", \"Codex when I ask\").")
    var expectedCaller: String?
    @Option(help: "With --create: how often it will be used: once, occasional or scheduled. Default once.")
    var frequency: UsageIntent.Frequency = .once
    @Flag(help: "With --create: it has to work with nobody at the Mac. Only makes sense with --frequency scheduled or occasional.")
    var background = false

    var template: ProviderTemplate? { provider.flatMap(ProviderCatalog.find) }
    /// Published provider spellings keep their previous default write target. New canonical IDs
    /// opt into new defaults; catalog discovery must never silently redirect an old save/replace.
    private var legacyDefaults: (id: String, field: String)? {
        switch provider?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "zhipu", "bigmodel", "glm", "智谱", "zhipu-ai":
            return ("zhipu", "zhipuai-api-key")
        case "zhipu-coding", "zhipu-coding-plan", "glm-coding-cn":
            return ("zhipu-coding", "zai-api-key")
        case "zai", "z.ai", "zai-api":
            return ("zai", "zai-api-key")
        case "zai-coding", "zai-coding-plan", "glm-coding-global":
            return ("zai-coding", "zai-api-key")
        default: return nil
        }
    }
    var credentialId: String { credential ?? legacyDefaults?.id ?? template?.id ?? "" }
    var fieldName: String { field ?? legacyDefaults?.field ?? template?.fieldName ?? "" }
    var templateField: ProviderFieldTemplate? { template?.field(named: fieldName) }
    var fileFormat: CredentialFileFormat? {
        guard fromFile != nil else { return nil }
        return templateField?.fileFormat ?? (template == nil ? .serviceAccountJSON : nil)
    }

    mutating func validate() throws {
        if let provider, template == nil {
            throw ValidationError("Unknown provider '\(provider)'. Run `keykeeper providers` to see the templates.")
        }
        guard !credentialId.isEmpty, !fieldName.isEmpty else {
            throw ValidationError("Give -c <credential-id> and --field <field-name>, or --provider <id> to take them from a template.")
        }
        if let template {
            guard let templateField else {
                throw ValidationError("Provider '\(template.id)' has no field named '\(fieldName)'. Run `keykeeper providers show \(template.id)` to see its fields.")
            }
            if create, templateField.name != template.primaryField.name {
                throw ValidationError("Create \(template.name) from its primary field '\(template.primaryField.name)' first. Add the other fields afterward.")
            }
            switch templateField.kind {
            case .secretFile:
                guard fromFile != nil else {
                    throw ValidationError("\(template.name) \(templateField.label) is a credential file. Use --from-file.")
                }
            case .secretText:
                guard fromFile == nil else {
                    throw ValidationError("\(template.name) \(templateField.label) is text, not a credential file. Use --from-clipboard or --from-browser.")
                }
            case .publicText:
                throw ValidationError("\(template.name) \(templateField.label) is non-secret metadata. Add or confirm it in the KeyKeeper app; do not send it through the secret importer.")
            case .localIdentity:
                throw ValidationError("\(template.name) uses a local macOS Keychain identity. KeyKeeper will not import or export its private key.")
            }
        }
        if (replaceExisting || expectedEd25519PublicKey != nil) && !fromClipboard {
            throw ClipboardSaveError.invalidReplacement
        }
        guard [fromClipboard, fromBrowser, fromFile != nil, fromSource != nil].filter({ $0 }).count == 1 else {
            throw ValidationError("Choose exactly one: --from-clipboard, --from-browser, --from-file or --from-source. Never put a key in command arguments.")
        }
        guard (fromSource != nil) == (pythonSymbol != nil) else {
            throw ValidationError("--from-source requires --python-symbol; --python-symbol is not valid with other sources.")
        }
        if security == .standard, intent == nil {
            throw ValidationError("--security standard needs --purpose: say in one line what unattended use this key is for.")
        }
        if (expectedCaller != nil || background || frequency != .once) && purpose == nil {
            throw ValidationError("--expected-caller, --frequency and --background describe a --purpose; add one.")
        }
        try request.validate()
        if let fromFile {
            guard fileFormat != nil else { throw ClipboardSaveError.wrongFieldType }
            try FileImportRequest(target: request, filePath: fromFile).validate()
        }
        if let fromSource, let pythonSymbol {
            try SourceImportRequest(target: request, filePath: fromSource, pythonSymbol: pythonSymbol).validate()
        }
    }
    var request: ClipboardSaveRequest {
        .init(credentialId: credentialId, fieldName: fieldName, create: create, expect: expect,
              useCurrentClipboard: useCurrentClipboard, replaceExisting: replaceExisting,
              expectedEd25519PublicKey: expectedEd25519PublicKey, security: security, expires: expires,
              intent: intent, provider: template?.id)
    }

    /// A refusal, with the app's one-line reason and the clipboard's shape when it gave them.
    static func failureMessage(_ result: ClipboardSaveResponse) -> String {
        var message = result.errorCode?.localizedDescription ?? "Save failed."
        if let detail = result.detail { message += " \(detail)" }
        if let shape = result.shape { message += " Clipboard holds: \(Self.storedSummary(shape))." }
        return message
    }

    /// " KeyKeeper verified it: …" after a save with a template; otherwise the old honest line.
    func verificationSuffix(_ result: ClipboardSaveResponse) -> String {
        if let validation = result.validation, validation != .skipped, let template {
            return " " + Self.validationNote(validation, provider: template.name)
        }
        return " Runtime/provider access is not verified."
    }

    /// A provider bundle is deliberately created from one secret at a time. Say what is still
    /// required instead of letting a successful primary save masquerade as a usable bundle.
    var remainingFieldsNote: String {
        guard create, let template else { return "" }
        let remaining = template.fields.filter { $0.required && $0.name != templateField?.name }
        guard !remaining.isEmpty else { return "" }
        let publicFields = remaining.filter { $0.kind == .publicText }.map(\.name)
        let secretFields = remaining.filter { $0.kind == .secretText || $0.kind == .secretFile }.map(\.name)
        var notes: [String] = []
        if !publicFields.isEmpty {
            notes.append("Add and confirm required non-secret fields: \(publicFields.joined(separator: ", ")).")
        }
        if !secretFields.isEmpty {
            notes.append("Add required secret fields through KeyKeeper's safe importer: \(secretFields.joined(separator: ", ")).")
        }
        return notes.isEmpty ? "" : " " + notes.joined(separator: " ")
    }

    /// What the provider said about the saved key, for the caller. Never a value.
    static func validationNote(_ validation: CredentialValidation, provider: String) -> String {
        switch validation {
        case .valid: return "KeyKeeper verified it: \(provider) accepted the key (read-only request)."
        case .invalid: return "KeyKeeper verified it: \(provider) rejected the key. It is saved, but wrong — check that you copied the whole key from the right account, then save again with --replace."
        case .unreachable: return "KeyKeeper could not reach \(provider) to verify the key (offline, rate-limited or an outage). It is saved; try the task and see."
        case .skipped: return ""
        }
    }
    /// The caller's declaration, sanitized here and again in the app.
    var intent: UsageIntent? {
        guard let purpose else { return nil }
        return UsageIntent(purpose: purpose, expectedCaller: expectedCaller, frequency: frequency, background: background).sanitized()
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
            guard result.success else { throw CommandFailure(Self.failureMessage(result)) }
            var note = "Saved source candidate. Original retained. No read permission was granted."
            note += verificationSuffix(result)
            note += remainingFieldsNote
            print(note)
            return
        }
        if let fromFile {
            let result = try IPCClient.requestFileImport(.init(target: request, filePath: fromFile))
            guard result.success else { throw CommandFailure(Self.failureMessage(result)) }
            var note = "Saved credential file. Original file retained. No read permission was granted."
            note += verificationSuffix(result)
            note += remainingFieldsNote
            print(note)
            return
        }
        if fromClipboard {
            print("Confirm in KeyKeeper. The window shows the first and last characters of what is on the clipboard, its length and when it was copied; copy again if it is not the right thing.")
            fflush(stdout)
        }
        let result = try IPCClient.requestClipboardSave(request, fromBrowser: fromBrowser) { url in
            print("Open this single-use URL, paste through the SAME clipboard transport used to copy, then confirm in KeyKeeper. Ordinary Chrome: native Copy + native Paste; do not mix browser-tool and system clipboards:")
            print(url); fflush(stdout)
        }
        guard result.success else {
            // On a shape refusal the App reports what was there instead: that is the fastest
            // way to see that the clipboard was overwritten between the copy and the save.
            throw CommandFailure(Self.failureMessage(result))
        }
        var note = fromBrowser ? "Saved. Browser clipboard was not cleared. No read permission was granted." : "Saved. Clipboard cleared if unchanged. No read permission was granted."
        if let shape = result.shape { note += " Stored: \(Self.storedSummary(shape))." }
        if replaceExisting { note += " Replaced the existing field. Existing permissions are unchanged." }
        if let validation = result.validation, validation != .skipped, let template {
            note += " " + Self.validationNote(validation, provider: template.name)
        }
        note += remainingFieldsNote
        print(note)
    }
}

extension SecurityLevel: ExpressibleByArgument {}
extension UsageIntent.Frequency: ExpressibleByArgument {}
extension RequestedDuration: ExpressibleByArgument {
    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}
