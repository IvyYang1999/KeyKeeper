import Foundation

public struct CredentialEditPlan: Sendable {
    public struct InputField: Sendable {
        public var name: String
        public var value: String
        /// The field's name when the editor opened, for fields that already existed.
        /// Lets a rename carry the stored value instead of looking like "delete + add empty".
        public var originalName: String?
        /// False for plain metadata (an account id, a region): the value lives in meta.json in
        /// the clear, never in the Keychain.
        public var isSecret: Bool

        public init(name: String, value: String, originalName: String? = nil, isSecret: Bool = true) {
            self.name = name
            self.value = value
            self.originalName = originalName
            self.isSecret = isSecret
        }
    }

    /// Move a stored value to a new field name. The caller reads `from`, writes `to`,
    /// and only then lets `valueDeletions` remove `from`.
    public struct ValueRename: Equatable, Sendable {
        public var from: String
        public var to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    public struct ValueWrite: Equatable, Sendable {
        public var fieldName: String
        public var value: String

        public init(fieldName: String, value: String) {
            self.fieldName = fieldName
            self.value = value
        }
    }

    public struct Metadata: Sendable {
        public var fields: [String: CredentialField]
        public var security: SecurityLevel

        public init(fields: [String: CredentialField], security: SecurityLevel) {
            self.fields = fields
            self.security = security
        }
    }

    public var valueWrites: [ValueWrite]
    public var valueRenames: [ValueRename]
    /// Every field whose name changed, old → new, whether or not its value moved. Earlier
    /// names are kept as aliases, and approvals listing them are moved by the caller.
    public var fieldRenames: [String: String]
    public var valueDeletions: [String]
    public var metadata: Metadata

    public init(
        inputFields: [InputField],
        existingFields: [String: CredentialField],
        security: SecurityLevel
    ) {
        var valueWrites: [ValueWrite] = []
        var valueRenames: [ValueRename] = []
        var fieldRenames: [String: String] = [:]
        var metadataFields: [String: CredentialField] = [:]

        /// The field as it existed, renamed: the old name joins its aliases.
        func carried(_ existing: CredentialField, from original: String, to name: String) -> CredentialField {
            var field = existing
            guard original != name else { return field }
            var aliases = (field.aliases ?? []).filter { $0 != name }
            if !aliases.contains(original) { aliases.append(original) }
            field.aliases = aliases
            return field
        }

        for field in inputFields where !field.name.isEmpty {
            let existing = field.originalName.flatMap { existingFields[$0] } ?? existingFields[field.name]

            if !field.isSecret {
                // Plain metadata. A secret becomes plain only when the editor actually has the
                // value in hand: otherwise the Keychain entry would be deleted with nothing to
                // put in its place, which is how a value goes missing for good.
                guard !field.value.isEmpty else {
                    if let existing, existing.secret {
                        metadataFields[field.name] = carried(existing, from: field.originalName ?? field.name, to: field.name)
                        if let original = field.originalName, original != field.name {
                            if existing.secret { valueRenames.append(.init(from: original, to: field.name)) }
                            fieldRenames[original] = field.name
                        }
                    }
                    continue
                }
                var plain = existing.map { carried($0, from: field.originalName ?? field.name, to: field.name) }
                    ?? CredentialField(secret: false)
                plain.secret = false
                plain.fileFormat = nil
                plain.value = field.value
                metadataFields[field.name] = plain
                if let original = field.originalName, original != field.name { fieldRenames[original] = field.name }
                continue
            }

            if !field.value.isEmpty {
                valueWrites.append(.init(fieldName: field.name, value: field.value))
                // A new value for a field that already existed keeps its display name and old names.
                if let original = field.originalName, let existing = existingFields[original] {
                    var kept = carried(existing, from: original, to: field.name)
                    kept.secret = true
                    kept.fileFormat = nil
                    kept.value = nil
                    metadataFields[field.name] = kept
                    if original != field.name { fieldRenames[original] = field.name }
                } else {
                    metadataFields[field.name] = CredentialField(secret: true)
                }
            } else if metadataFields[field.name] == nil, let existingField = existingFields[field.name] {
                metadataFields[field.name] = existingField
            } else if metadataFields[field.name] == nil,
                      let original = field.originalName, original != field.name,
                      let existingField = existingFields[original] {
                // Renamed without revealing: the editor never had the value, so move it.
                if existingField.secret {
                    valueRenames.append(.init(from: original, to: field.name))
                }
                metadataFields[field.name] = carried(existingField, from: original, to: field.name)
                fieldRenames[original] = field.name
            }
        }

        self.valueWrites = valueWrites
        self.valueRenames = valueRenames
        self.fieldRenames = fieldRenames
        // Delete a Keychain entry when metadata no longer refers to it, and also when the
        // field is still there but has become plain (its value now lives in meta.json).
        self.valueDeletions = existingFields
            .filter { name, field in
                guard field.secret else { return false }
                // Still a secret under the same name: keep it. Gone (removed or renamed away)
                // or now plain (its value moved into meta.json): the Keychain entry must go.
                guard let now = metadataFields[name] else { return true }
                return now.secret == false
            }
            .map(\.key)
            .sorted()
        self.metadata = Metadata(fields: metadataFields, security: security)
    }
}
