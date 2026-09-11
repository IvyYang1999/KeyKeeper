import Foundation

/// A change to the names and notes of one credential. Never touches values or security.
public struct MetadataEdit: Codable, Sendable, Equatable {
    public var newGroupId: String?
    public var title: String?
    public var notes: String?
    /// Current (or earlier) field name → new machine name.
    public var fieldRenames: [String: String]
    /// Field name → display name; blank clears it.
    public var fieldDisplayNames: [String: String]

    public init(newGroupId: String? = nil, title: String? = nil, notes: String? = nil,
                fieldRenames: [String: String] = [:], fieldDisplayNames: [String: String] = [:]) {
        self.newGroupId = newGroupId
        self.title = title
        self.notes = notes
        self.fieldRenames = fieldRenames
        self.fieldDisplayNames = fieldDisplayNames
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        newGroupId = try c.decodeIfPresent(String.self, forKey: .newGroupId)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        fieldRenames = try c.decodeIfPresent([String: String].self, forKey: .fieldRenames) ?? [:]
        fieldDisplayNames = try c.decodeIfPresent([String: String].self, forKey: .fieldDisplayNames) ?? [:]
    }
}

/// What an edit did, for the change log and for telling the person.
public enum MetadataChange: Codable, Sendable, Equatable {
    case groupRenamed(from: String, to: String)
    case fieldRenamed(from: String, to: String)
    case titleChanged(from: String, to: String)
    case notesChanged
    case displayNameChanged(field: String, to: String?)

    /// Plain English, for CLI output and agents.
    public var summary: String {
        switch self {
        case .groupRenamed(let from, let to): return "group ID \(from) → \(to) (the old ID keeps working)"
        case .fieldRenamed(let from, let to): return "field \(from) → \(to) (the old name and its variable keep working)"
        case .titleChanged(let from, let to): return "title \"\(from)\" → \"\(to)\""
        case .notesChanged: return "notes updated"
        case .displayNameChanged(let field, let to): return to.map { "field \(field) is now shown as \"\($0)\"" } ?? "field \(field) display name cleared"
        }
    }
}

public enum MetadataEditError: Error, Equatable, LocalizedError {
    case notFound(String)
    case invalidGroupId(String)
    case groupIdTaken(String)
    case fieldNotFound(String)
    case invalidFieldName(String)
    case fieldNameTaken(String)
    case tooLong(String)
    case nothingToChange

    public var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No credential is called '\(id)'. Run 'keykeeper list' to see the IDs."
        case .invalidGroupId(let id): return "'\(id)' is not a valid group ID. Use lowercase letters, digits, '-', '_' or '.', starting with a letter or digit (at most 64)."
        case .groupIdTaken(let id): return "'\(id)' is already used by another credential, now or in the past. Old names stay reserved."
        case .fieldNotFound(let name): return "This credential has no field called '\(name)'."
        case .invalidFieldName(let name): return "'\(name)' is not a valid field name. Use letters, digits, '-', '_' or '.', starting with a letter or digit (at most 64)."
        case .fieldNameTaken(let name): return "'\(name)' is already a field name (or an old one) in this credential."
        case .tooLong(let what): return "The \(what) is too long."
        case .nothingToChange: return "Nothing to change."
        }
    }
}

public struct MetadataEditResult: Sendable {
    public var meta: MetaFile
    /// The group ID before and after.
    public var previousGroupId: String
    public var groupId: String
    /// Field renames by their names before the edit.
    public var fieldMap: [String: String]
    public var changes: [MetadataChange]
}

public enum MetadataEditPlan {
    static let titleLimit = 200
    static let notesLimit = 4000
    static let displayNameLimit = 200

    public static func apply(_ edit: MetadataEdit, to meta: MetaFile, groupId name: String,
                             today: String = MetadataEditPlan.today()) throws -> MetadataEditResult {
        guard let groupId = meta.resolveGroupId(name), var credential = meta.credentials[groupId] else {
            throw MetadataEditError.notFound(name)
        }
        var changes: [MetadataChange] = []
        var fieldMap: [String: String] = [:]
        var finalGroupId = groupId

        if let newId = edit.newGroupId, newId != groupId {
            guard CredentialNames.isValidGroupId(newId) else { throw MetadataEditError.invalidGroupId(newId) }
            guard !meta.groupIdIsTaken(newId, except: groupId) else { throw MetadataEditError.groupIdTaken(newId) }
            var aliases = (credential.aliases ?? []).filter { $0 != newId }
            if !aliases.contains(groupId) { aliases.append(groupId) }
            credential.aliases = aliases
            finalGroupId = newId
            changes.append(.groupRenamed(from: groupId, to: newId))
        }

        // Display names refer to fields by their names before any rename in the same edit.
        var displayNames: [String: String] = [:]
        for (field, display) in edit.fieldDisplayNames {
            guard let current = credential.resolveFieldName(field) else { throw MetadataEditError.fieldNotFound(field) }
            displayNames[current] = display
        }

        for (from, to) in edit.fieldRenames.sorted(by: { $0.key < $1.key }) {
            guard let current = credential.resolveFieldName(from), var field = credential.fields[current] else {
                throw MetadataEditError.fieldNotFound(from)
            }
            guard to != current else { continue }
            guard CredentialNames.isValidFieldName(to) else { throw MetadataEditError.invalidFieldName(to) }
            let takenElsewhere = credential.fields.contains { key, other in
                key != current && (key == to || other.aliases?.contains(to) == true)
            }
            guard !takenElsewhere else { throw MetadataEditError.fieldNameTaken(to) }
            var aliases = (field.aliases ?? []).filter { $0 != to }
            if !aliases.contains(current) { aliases.append(current) }
            field.aliases = aliases
            credential.fields.removeValue(forKey: current)
            credential.fields[to] = field
            if let display = displayNames.removeValue(forKey: current) { displayNames[to] = display }
            fieldMap[current] = to
            changes.append(.fieldRenamed(from: current, to: to))
        }

        for (field, display) in displayNames.sorted(by: { $0.key < $1.key }) {
            let trimmed = display.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count <= displayNameLimit else { throw MetadataEditError.tooLong("display name") }
            let value = trimmed.isEmpty ? nil : trimmed
            guard credential.fields[field]?.displayName != value else { continue }
            credential.fields[field]?.displayName = value
            changes.append(.displayNameChanged(field: field, to: value))
        }

        if let title = edit.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty, title != credential.label {
            guard title.count <= titleLimit else { throw MetadataEditError.tooLong("title") }
            changes.append(.titleChanged(from: credential.label, to: title))
            credential.label = title
        }
        if let notes = edit.notes, notes != credential.notes {
            guard notes.count <= notesLimit else { throw MetadataEditError.tooLong("notes") }
            credential.notes = notes
            changes.append(.notesChanged)
        }

        guard !changes.isEmpty else { throw MetadataEditError.nothingToChange }
        credential.updated = today
        var result = meta
        result.credentials.removeValue(forKey: groupId)
        result.credentials[finalGroupId] = credential
        return MetadataEditResult(meta: result, previousGroupId: groupId, groupId: finalGroupId,
                                  fieldMap: fieldMap, changes: changes)
    }

    public static func today() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
