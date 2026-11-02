import Foundation
import KeyKeeperCore

enum ValueAvailabilityQuery {
    static func result(id: String, record: Credential, inventory: [String: [String]]?) -> CredentialValueAvailability {
        guard let inventory else { return .init(state: .unavailable) }
        return .check(record, presentFields: Set(inventory[id] ?? []))
    }

    static func metadataJSON(_ record: Credential, availability: CredentialValueAvailability) throws -> Data {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(record)) as! [String: Any]
        object["valueStatus"] = try JSONSerialization.jsonObject(with: encoder.encode(availability))
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
