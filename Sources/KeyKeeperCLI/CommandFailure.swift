import Foundation

/// A runtime failure (not an argument-parsing problem). ArgumentParser prints
/// `ValidationError`s together with the usage block, which buries the actual
/// message ("Credential not found … Usage: keykeeper <subcommand>"); this type
/// prints just the message and exits non-zero.
struct CommandFailure: Error, CustomStringConvertible, LocalizedError {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    var errorDescription: String? { description }
}
