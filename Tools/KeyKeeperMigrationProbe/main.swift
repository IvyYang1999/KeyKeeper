import Foundation
import KeyKeeperCore
import Darwin

// Signed seam harness only. It cannot resolve a production namespace or accept a source path.
// Seed writes one dedicated synthetic item under an old-identity test App. Verify invokes the
// actual old helper from a new-identity test App and compares without printing values.
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
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/KeyKeeperMigrationBridge")
        let source = try await IdentityMigrationBridge.read(from: helper)
        let meta = try JSONDecoder().decode(MetaFile.self, from: source.metadata ?? Data())
        guard meta.credentials.count == 1,
              meta.credentials["migration-fixture"]?.label == "Synthetic migration fixture",
              source.values == Data(#"{"version":1,"credentials":{"migration-fixture":{"api-key":"synthetic-identity-migration"}}}"#.utf8),
              source.integrityKey == nil, source.approvals == nil, source.browserSessions == nil, source.proposals == nil else {
            throw IdentityMigrationError.malformed
        }
        print("PASS signed migration pipe synthetic source preserved grants_not_transferred")
    default: throw IdentityMigrationError.identity
    }
} catch {
    print("FAIL migration_probe")
    exit((error as? IdentityMigrationError)?.exitCode ?? IdentityMigrationError.unavailable.exitCode)
}
