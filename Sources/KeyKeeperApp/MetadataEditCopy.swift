import Foundation
import KeyKeeperCore

/// Interface wording for name/notes edits, localized (the Core messages are for the CLI).
enum MetadataEditCopy {
    static func message(_ error: MetadataEditError) -> String {
        switch error {
        case .notFound(let id): return L("No key group is called \u{201C}\(id)\u{201D}.")
        case .invalidGroupId: return L("Group IDs can only use lowercase letters, digits, '-', '_' and '.', starting with a letter or digit.")
        case .groupIdTaken(let id): return L("\u{201C}\(id)\u{201D} is already used by another key group, now or in the past. Old names stay reserved.")
        case .fieldNotFound(let name): return L("There is no field called \u{201C}\(name)\u{201D}.")
        case .invalidFieldName: return L("Field names can only use letters, digits, '-', '_' and '.', with no spaces. Put the wording you like in the display name.")
        case .fieldNameTaken(let name): return L("\u{201C}\(name)\u{201D} is already a field name here, now or in the past.")
        case .fieldIsSecret(let name): return L("\u{201C}\(name)\u{201D} is a secret field. Change it in KeyKeeper, where the value stays in the Keychain.")
        case .reservedFieldName(let name): return L("\u{201C}\(name)\u{201D} would become an environment variable that decides how programs run, like PATH. Pick another name.")
        case .tooLong: return L("That text is too long.")
        case .invalidExpiry: return L("Use a date like 2026-12-31, or never to clear it.")
        case .unknownProvider: return L("That is not a provider template.")
        case .nothingToChange: return L("Nothing to change.")
        }
    }

    static func text(_ change: MetadataChange) -> String {
        switch change {
        case .groupRenamed(let from, let to): return L("Group ID \(from) → \(to)")
        case .fieldRenamed(let from, let to): return L("Field \(from) → \(to)")
        case .plainFieldSet(let field, let value): return L("Plain field \(field) = \(value)")
        case .plainFieldRemoved(let field): return L("Plain field \(field) removed")
        case .titleChanged(_, let to): return L("Title → \u{201C}\(to)\u{201D}")
        case .notesChanged: return L("Notes updated")
        case .displayNameChanged(let field, let to):
            return to.map { L("\(field) shown as \u{201C}\($0)\u{201D}") } ?? L("\(field) display name cleared")
        case .expiryChanged(_, let to):
            return to.map { L("Expires \($0)") } ?? L("Expiry date cleared")
        case .providerChanged(_, let to):
            return to.map { L("Provider → \($0)") } ?? L("Provider unbound")
        }
    }

    /// "claude changed GA4 报表"
    static func headline(_ record: MetadataChangeRecord) -> String {
        L("\(record.caller) changed \u{201C}\(record.label)\u{201D}")
    }
}
