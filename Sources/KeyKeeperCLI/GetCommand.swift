import ArgumentParser
import KeyKeeperCore

struct GetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Get a field value for a credential"
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    @Argument(help: "Field name")
    var fieldName: String

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        guard let cred = meta.credentials[credentialId] else {
            throw ValidationError("Credential '\(credentialId)' not found")
        }
        guard let field = cred.fields[fieldName] else {
            throw ValidationError("Field '\(fieldName)' not found in '\(credentialId)'")
        }

        if field.secret {
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
