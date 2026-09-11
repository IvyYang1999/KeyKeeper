import Foundation

public struct CredentialEditPlan: Sendable {
    public struct InputField: Sendable {
        public var name: String
        public var value: String
        /// The field's name when the editor opened, for fields that already existed.
        /// Lets a rename carry the stored value instead of looking like "delete + add empty".
        public var originalName: String?

        public init(name: String, value: String, originalName: String? = nil) {
            self.name = name
            self.value = value
            self.originalName = originalName
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
    public var valueDeletions: [String]
    public var metadata: Metadata

    public init(
        inputFields: [InputField],
        existingFields: [String: CredentialField],
        security: SecurityLevel
    ) {
        var valueWrites: [ValueWrite] = []
        var valueRenames: [ValueRename] = []
        var metadataFields: [String: CredentialField] = [:]

        for field in inputFields where !field.name.isEmpty {
            if !field.value.isEmpty {
                valueWrites.append(.init(fieldName: field.name, value: field.value))
                metadataFields[field.name] = CredentialField(secret: true)
            } else if metadataFields[field.name] == nil, let existingField = existingFields[field.name] {
                metadataFields[field.name] = existingField
            } else if metadataFields[field.name] == nil,
                      let original = field.originalName, original != field.name,
                      let existingField = existingFields[original] {
                // Renamed without revealing: the editor never had the value, so move it.
                if existingField.secret {
                    valueRenames.append(.init(from: original, to: field.name))
                }
                metadataFields[field.name] = existingField
            }
        }

        self.valueWrites = valueWrites
        self.valueRenames = valueRenames
        self.valueDeletions = existingFields
            .filter { $0.value.secret && metadataFields[$0.key] == nil }
            .map(\.key)
            .sorted()
        self.metadata = Metadata(fields: metadataFields, security: security)
    }
}
