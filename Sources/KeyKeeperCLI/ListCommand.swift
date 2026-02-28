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
            if detail {
                if !cred.notes.isEmpty {
                    print("  notes: \(cred.notes)")
                }
                for link in cred.links {
                    print("  link: \(link)")
                }
                for (fieldName, field) in cred.fields.sorted(by: { $0.key < $1.key }) {
                    if field.secret {
                        print("  \(fieldName): ********")
                    } else {
                        print("  \(fieldName): \(field.value ?? "")")
                    }
                }
            }
            print()
        }
    }
}
