import ArgumentParser
import KeyKeeperCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List all stored credentials"
    )

    @Flag(name: .long, help: "Show plain-text field values")
    var detail = false

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()

        if meta.credentials.isEmpty {
            print("No credentials stored. Use the KeyKeeper app to add credentials.")
            return
        }

        for (id, cred) in meta.credentials.sorted(by: { $0.key < $1.key }) {
            print("\(id) | \(cred.label)")
            // Its own indented line: the SDKs read the id as the text before " | ".
            if let expiry = CredentialExpiry.summary(cred.expires) {
                print("  expires: \(expiry)")
            }
            if cred.isInjectOnly {
                print("  inject-only: use keykeeper run; get is refused")
            }
            if let provider = cred.provider {
                print("  provider: \(provider) (keykeeper providers show \(provider))")
            }
            if detail {
                if let aliases = cred.aliases, !aliases.isEmpty {
                    print("  also answers to: \(aliases.joined(separator: ", "))")
                }
                if !cred.notes.isEmpty {
                    print("  notes: \(cred.notes)")
                }
                for link in cred.links {
                    print("  link: \(link)")
                }
                for (fieldName, field) in cred.fields.sorted(by: { $0.key < $1.key }) {
                    var label = fieldName
                    if let display = field.displayName { label += " (\(display))" }
                    if let aliases = field.aliases, !aliases.isEmpty { label += " [was: \(aliases.joined(separator: ", "))]" }
                    if field.secret {
                        print("  \(label): ********")
                    } else {
                        print("  \(label): \(field.value ?? "")")
                    }
                }
            }
            print()
        }
    }
}
