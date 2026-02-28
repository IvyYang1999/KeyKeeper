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
            let keychain = KeychainService()
            let value = try keychain.retrieve(credentialId: credentialId, fieldName: fieldName)
            print(value, terminator: "")
        } else {
            print(field.value ?? "", terminator: "")
        }
    }
}
