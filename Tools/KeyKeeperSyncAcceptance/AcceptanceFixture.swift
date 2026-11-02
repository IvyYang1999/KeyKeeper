#if KEYKEEPER_SYNC_ACCEPTANCE
import Foundation
import CryptoKit
import KeyKeeperCore

enum AcceptanceFixture {
    static func snapshot(runID: UUID, advanced: Bool) throws -> CloudVaultSnapshot {
        let item = Credential(label: "Synthetic sync acceptance", notes: advanced ? "Changed on client B" : "Created on client A",
            links: [], fields: ["key": .init(secret: true)], security: .strict,
            created: "2026-11-02", updated: advanced ? "2026-11-03" : "2026-11-02")
        return try .init(credentials: [credentialID(runID): .init(metadata: item,
            secrets: ["key": advanced ? "synthetic-value-B" : "synthetic-value-A"])])
    }
    static func credentialID(_ runID: UUID) -> String { "fixture-" + runID.uuidString.lowercased() }
    static func digest(_ snapshot: CloudVaultSnapshot) throws -> String {
        SHA256.hash(data: try snapshot.encoded()).map { String(format: "%02x", $0) }.joined()
    }
    static func empty() throws -> CloudVaultSnapshot { try .init(credentials: [:]) }
    static func matches(_ actual: CloudVaultSnapshot, _ expected: CloudVaultSnapshot) throws -> Bool {
        try actual.encoded() == expected.encoded()
    }
    static func selfTest() throws {
        let run = UUID(), a = try snapshot(runID: run, advanced: false), b = try snapshot(runID: run, advanced: true)
        let id = credentialID(run)
        guard try digest(a) != digest(b), a.credentials[id]?.metadata.notes != b.credentials[id]?.metadata.notes,
              a.credentials[id]?.secrets != b.credentials[id]?.secrets,
              try matches(CloudVaultSnapshot.decode(a.encoded()), a),
              !String(decoding: try a.encoded(), as: UTF8.self).contains("approvals")
        else { throw AcceptanceFailure.state }
    }
}
#endif
