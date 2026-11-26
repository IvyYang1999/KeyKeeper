import Foundation
import KeyKeeperCore
import Darwin

// Signed seam harness only. It cannot resolve a production namespace or accept a source path.
// Seed writes one dedicated synthetic item under an old-identity test App. Verify asks the actual
// old-identity XPC service bundled in a new-identity test App and compares without printing
// values. Presence runs, as the new App, the read-only check Settings uses to say which old items
// are left: it must name the synthetic item without reading it. Nothing here deletes anything.
do {
    guard let fixture = try IdentityMigrationFixture.resolve(environment: ProcessInfo.processInfo.environment),
          CommandLine.arguments.count == 2 else { throw IdentityMigrationError.identity }
    switch CommandLine.arguments[1] {
    case "seed":
        try IdentityMigrationSignature.current(.legacy)
        let io = SecItemBlobIO(service: fixture.service, identity: .legacy)
        guard try io.readBlobWithoutInteraction() == nil,
              !FileManager.default.fileExists(atPath: fixture.directory.path) else { throw IdentityMigrationError.destinationConflict }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let meta = MetaFile(credentials: ["migration-fixture": Credential(label: "Synthetic migration fixture", notes: "Synthetic note", links: [],
            fields: ["api-key": .init(secret: true)], security: .strict, created: "2026-11-02", updated: "2026-11-02")])
        let metadata = try JSONEncoder().encode(meta)
        try metadata.write(to: fixture.directory.appendingPathComponent("meta.json"), options: .withoutOverwriting)
        let value = Data(#"{"version":1,"credentials":{"migration-fixture":{"api-key":"synthetic-identity-migration"}}}"#.utf8)
        try io.writeBlob(value, replacingExisting: false)
        guard try io.readBlobWithoutInteraction() == value else { throw IdentityMigrationError.unavailable }
        print("PASS seeded synthetic migration source")
    case "verify":
        try IdentityMigrationSignature.current(.current)
        let source = try await IdentityMigrationBridge.read(fixture: fixture)
        let meta = try JSONDecoder().decode(MetaFile.self, from: source.metadata ?? Data())
        guard meta.credentials.count == 1,
              meta.credentials["migration-fixture"]?.label == "Synthetic migration fixture",
              source.values == Data(#"{"version":1,"credentials":{"migration-fixture":{"api-key":"synthetic-identity-migration"}}}"#.utf8),
              source.integrityKey == nil, source.approvals == nil, source.browserSessions == nil, source.proposals == nil else {
            throw IdentityMigrationError.malformed
        }
        print("PASS signed migration xpc synthetic source preserved grants_not_transferred")
    case "presence":
        try IdentityMigrationSignature.current(.current)
        let names = IdentityMigrationLegacyCapture.itemServices(fixture: fixture)
        guard try LegacyItemPresence.remaining(services: names) == [fixture.service] else {
            throw IdentityMigrationError.malformed
        }
        print("PASS signed migration presence names_synthetic_item")
    default: throw IdentityMigrationError.identity
    }
} catch {
    print("FAIL migration_probe")
    exit((error as? IdentityMigrationError)?.exitCode ?? IdentityMigrationError.unavailable.exitCode)
}
