import Foundation

/// A local point-in-time value-presence check, not provider validity or a read grant.
/// Only names and states may cross the App boundary; never the underlying blob.
public struct CredentialValueAvailability: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case unchecked, present, missing, unavailable }
    public let state: State
    public let missingFields: [String]

    public init(state: State, missingFields: [String] = []) {
        self.state = state
        self.missingFields = missingFields.sorted()
    }

    public static func check(_ record: Credential, presentFields: Set<String>) -> Self {
        let required = Set(record.fields.filter { $0.value.secret }.keys)
        let missing = required.subtracting(presentFields).sorted()
        return .init(state: missing.isEmpty ? .present : .missing, missingFields: missing)
    }
}
