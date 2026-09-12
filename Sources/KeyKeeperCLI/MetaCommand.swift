import ArgumentParser
import Foundation
import KeyKeeperCore

struct MetaCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "meta",
        abstract: "Show credential metadata as JSON (no secret values)"
    )

    @Argument(help: "Credential ID")
    var credentialId: String

    func run() throws {
        let store = MetaStore.default
        let meta = try store.load()
        let data = try Self.metadataJSON(credentialId: credentialId, meta: meta, inventory: ValueAvailabilityQuery.inventory())
        print(String(decoding: data, as: UTF8.self))
    }

    static func metadataJSON(credentialId: String, meta: MetaFile, inventory: [String: [String]]?) throws -> Data {
        guard let id = meta.resolveGroupId(credentialId), let cred = meta.credentials[id] else {
            throw CommandFailure("Credential '\(credentialId)' not found. Run 'keykeeper list' to see the available IDs.")
        }

        let availability = ValueAvailabilityQuery.result(id: id, record: cred, inventory: inventory)
        return try ValueAvailabilityQuery.metadataJSON(cred, availability: availability)
    }
}
