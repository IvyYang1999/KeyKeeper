import Foundation
import KeyKeeperCore

/// What kind of thing a stored key is, so lists can show it at a glance.
enum CredentialKind: Equatable {
    /// Ordinary text values (API keys, tokens, URLs).
    case text
    /// A service-account JSON file: contents are never shown, only used through a private file.
    case serviceAccountFile

    init(_ credential: Credential) {
        self = credential.fields.values.contains { $0.fileFormat != nil } ? .serviceAccountFile : .text
    }
}
