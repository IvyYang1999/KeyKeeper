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

    @Flag(name: .long, help: "Print the secret even though stdout is a terminal.")
    var reveal = false

    static let terminalRefusalMessage =
        "Refusing to print a secret to the terminal (it would stay in scrollback and AI tool context). " +
        "Use 'keykeeper run -c <id> -- <command>' to inject it, or add --reveal to print it anyway."

    /// Secrets go to pipes (SDKs) freely; to a terminal only when explicitly asked.
    static func refusesToPrint(stdoutIsTerminal: Bool, reveal: Bool) -> Bool {
        stdoutIsTerminal && !reveal
    }

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        guard let cred = meta.credentials[credentialId] else {
            throw ValidationError("Credential '\(credentialId)' not found. Run 'keykeeper list' to see the available IDs.")
        }
        guard let field = cred.fields[fieldName] else {
            throw ValidationError("Field '\(fieldName)' not found in '\(credentialId)'. Run 'keykeeper list --detail' to see its fields.")
        }

        if field.secret {
            if Self.refusesToPrint(stdoutIsTerminal: isatty(STDOUT_FILENO) == 1, reveal: reveal) {
                throw ValidationError(Self.terminalRefusalMessage)
            }
            let session = SessionResolver.resolve()

            // For strict credentials, check/request grant first
            if cred.security == .strict {
                let grantStore = GrantStore.default
                try RunCommand.ensureGrant(
                    credentialId: credentialId, credential: cred,
                    grantStore: grantStore, session: session
                )
            }

            // Read secret via IPC — App owns the unlocked age session
            let value = try IPCClient.requestValue(
                credentialId: credentialId, fieldName: fieldName,
                sessionId: session.id,
                requestedFieldNames: [fieldName])
            print(value, terminator: "")
        } else {
            print(field.value ?? "", terminator: "")
        }
    }
}
