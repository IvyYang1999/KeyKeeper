import Foundation

public struct CredentialEditPlan: Sendable {
    public struct InputField: Sendable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
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
    public var valueDeletions: [String]
    public var metadata: Metadata

    public init(
        inputFields: [InputField],
        existingFields: [String: CredentialField],
        security: SecurityLevel
    ) {
        var valueWrites: [ValueWrite] = []
        var metadataFields: [String: CredentialField] = [:]

        for field in inputFields where !field.name.isEmpty {
            if !field.value.isEmpty {
                valueWrites.append(.init(fieldName: field.name, value: field.value))
                metadataFields[field.name] = CredentialField(secret: true)
            } else if metadataFields[field.name] == nil, let existingField = existingFields[field.name] {
                metadataFields[field.name] = existingField
            }
        }

        self.valueWrites = valueWrites
        self.valueDeletions = existingFields
            .filter { $0.value.secret && metadataFields[$0.key] == nil }
            .map(\.key)
            .sorted()
        self.metadata = Metadata(fields: metadataFields, security: security)
    }
}
