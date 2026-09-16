import ArgumentParser
import Foundation
import KeyKeeperCore

/// `keykeeper import ./.env`: the App reads the file, shows the variable names, and stores the
/// values. The CLI never opens the file; it only says where it is.
struct ImportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Move a project's .env file into KeyKeeper: one credential, one field per variable.",
        discussion: """
        The KeyKeeper app opens the file itself and asks the person to approve the list of variable \
        names. All imported values go into the macOS Keychain, including ordinary settings; none \
        are guessed safe to expose as plain metadata. The credential is inject-only: use \
        `keykeeper run -c <id> -- <command>` to inject the imported variables. Only single-line \
        assignments are supported; quotes, escapes and comments are parsed, but shell expansion \
        is not performed. Malformed or multiline syntax is refused. Empty, reserved or unsupported \
        variable names are skipped. Keep the original until the project works through run.
        """)

    @Argument(help: "Path to the .env file (.env, .env.*, or *.env; at most 64 KiB).")
    var path: String
    @Option(name: [.customShort("c"), .long], help: "Credential ID (default: the folder the file is in).")
    var id: String?
    @Option(help: "Display name for the credential (default: the ID).")
    var label: String?
    @Option(help: "What this project's keys are for, in one line. Required with --security standard.")
    var purpose: String?
    @Option(help: "strict asks every time (the default); standard lets background callers use it after a one-time approval each.")
    var security: SecurityLevel?

    func validate() throws {
        if security == .standard, purpose == nil {
            throw ValidationError("--security standard needs a --purpose so the person knows what unattended use this is for.")
        }
    }

    mutating func run() throws {
        let absolute = URL(fileURLWithPath: path).standardizedFileURL.path
        let credentialId = id ?? CredentialNames.slug(URL(fileURLWithPath: absolute).deletingLastPathComponent().lastPathComponent)
        guard CredentialNames.isValidGroupId(credentialId) else {
            throw ValidationError("Could not derive a credential ID from the folder name; pass --id <name> (lowercase letters, digits, - _ .).")
        }
        let request = EnvImportRequest(credentialId: credentialId, filePath: absolute, label: label,
                                       intent: purpose.flatMap { UsageIntent(purpose: $0, expectedCaller: nil, frequency: .once, background: false).sanitized() },
                                       security: security)
        print("Confirm in KeyKeeper. The window lists the variable names it found in \((absolute as NSString).lastPathComponent); no value is shown to you or to it.")
        fflush(stdout)
        let result = try IPCClient.requestEnvImport(request)
        guard result.success else {
            throw CommandFailure(result.errorCode?.errorDescription ?? "Import failed.")
        }
        print("""
        Imported into `\(credentialId)` (\(result.detail ?? "done")). The original file is untouched.
        Next:
          keykeeper run -c \(credentialId) -- <your command>     # same variables, no file
        Tell the person to delete the .env from the project (add it to .gitignore) and to rotate keys that sat in plaintext.
        """)
    }
}
