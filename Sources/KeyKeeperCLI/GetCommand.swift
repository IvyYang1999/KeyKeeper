import Foundation
import ArgumentParser
import Darwin
import KeyKeeperCore

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a field value for a credential",
        discussion: """
        Intended for the SDKs, which read the value over a pipe. When stdout is a \
        terminal the secret would land in scrollback and in any AI tool watching the \
        session, so the command refuses unless --reveal is given. Prefer \
        'keykeeper run -c <id> -- <command>' to use a secret without ever printing it.
        """
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    @Argument(help: "Field name")
    var fieldName: String

    @Option(name: .long, help: "One line for the human: why you need this key and what you will do with it. Shown in the approval window, marked as unverified; it never changes what an approval grants.")
    var reason: String?

    @Option(name: .long, help: "How long you ask to be approved for: once, run (while this process or terminal session lives) or always. A wish the person sees next to KeyKeeper's own suggestion; they decide. session and 1h are accepted as older spellings of run.")
    var duration: RequestedDuration?

    @Flag(name: .long, help: "Print the secret even though stdout is a terminal.")
    var reveal = false

    static let terminalRefusalMessage =
        "Refusing to print a secret to the terminal (it would stay in scrollback and AI tool context). " +
        "Use 'keykeeper run -c <id> -- <command>' to inject it, or add --reveal to print it anyway."

    /// Secrets go to pipes (SDKs) freely; to a terminal only when explicitly asked.
    static func refusesToPrint(stdoutIsTerminal: Bool, reveal: Bool) -> Bool {
        stdoutIsTerminal && !reveal
    }

    /// The caller's own sentence for the approval window, folded to one line and capped.
    func statedReason() -> CallerStatedReason? {
        CallerStatedReason.sanitize(reason)
    }

    /// Said before anyone is asked: an inject-only credential never comes back through `get`.
    static func injectOnlyRefusal(credentialId: String, credential: Credential) -> String? {
        guard credential.isInjectOnly else { return nil }
        return "'\(credentialId)' is inject-only: use `keykeeper run -c \(credentialId) -- <command>` so the value goes into that command's environment without being printed. The person can allow reading it out in KeyKeeper (credential page → Can be read out)."
    }

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        // Earlier group IDs and field names keep working.
        guard let credentialId = meta.resolveGroupId(self.credentialId), let cred = meta.credentials[credentialId] else {
            throw CommandFailure("Credential '\(self.credentialId)' not found. Run 'keykeeper list' to see the available IDs.")
        }
        guard let fieldName = cred.resolveFieldName(self.fieldName), let field = cred.fields[fieldName] else {
            throw CommandFailure("Field '\(self.fieldName)' not found in '\(credentialId)'. Run 'keykeeper list --detail' to see its fields.")
        }
        if let warning = CredentialExpiry.warning(credentialId: credentialId, expires: cred.expires) {
            FileHandle.standardError.write(Data((warning + "\n").utf8))
        }

        if field.secret {
            if let refusal = Self.injectOnlyRefusal(credentialId: credentialId, credential: cred) {
                throw CommandFailure(refusal)
            }
            if Self.refusesToPrint(stdoutIsTerminal: isatty(STDOUT_FILENO) == 1, reveal: reveal) {
                throw CommandFailure(Self.terminalRefusalMessage)
            }
            let session = SessionResolver.resolve()

            // Read via IPC; the app asks for approval when this caller holds none.
            let value = try RunCommand.readSecret(
                credentialId: credentialId, credential: cred, fieldName: fieldName,
                requestedFieldNames: [fieldName], session: session, statedReason: statedReason(),
                requestedDuration: duration, commandSummary: "keykeeper get \(credentialId) \(fieldName)",
                purpose: .read)
            print(value, terminator: "")
        } else {
            // This value comes straight out of meta.json, so it is only as trustworthy as that file.
            let verdict = IPCClient.requestMetadataIntegrity()
            guard PlainValuePolicy.mayServe(verdict) else {
                throw CommandFailure(PlainValueRefusal.message(for: verdict))
            }
            print(field.value ?? "", terminator: "")
        }
    }
}
