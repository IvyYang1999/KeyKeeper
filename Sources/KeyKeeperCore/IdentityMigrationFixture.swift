import Foundation

/// The signed seam harness is explicitly isolated. A partial override never reaches production.
/// Only this dedicated test namespace is accepted, in addition to the existing three-part gate.
public struct IdentityMigrationFixture: Sendable {
    public let service: String
    public let directory: URL
    public let socket: String
    public static func resolve(environment: [String: String]) throws -> Self? {
        let keys = ["KEYKEEPER_KEYCHAIN_SERVICE", "KEYKEEPER_DATA_DIR", "KEYKEEPER_TEST_SOCKET"]
        guard keys.contains(where: { environment[$0] != nil }) else { return nil }
        guard let service = environment[keys[0]], service.hasPrefix("com.keykeeper.test.migration."),
              let dataPath = environment[keys[1]], let socket = environment[keys[2]],
              socket.hasPrefix("/tmp/keykeeper-test-migration-"),
              IPCConstants.resolveSocketPath(environment: environment) == socket else { throw IdentityMigrationError.identity }
        let suffix = String(service.dropFirst("com.keykeeper.test.migration.".count))
        guard UUID(uuidString: suffix) != nil,
              socket == "/tmp/keykeeper-test-migration-\(suffix).sock" else { throw IdentityMigrationError.identity }
        let directory = URL(fileURLWithPath: dataPath, isDirectory: true).standardizedFileURL
        let expected = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("keykeeper-migration-\(suffix)", isDirectory: true)
        guard directory.resolvingSymlinksInPath() == expected, directory.path == expected.path else { throw IdentityMigrationError.identity }
        return .init(service: service, directory: directory, socket: socket)
    }
    public var environment: [String: String] {
        ["KEYKEEPER_KEYCHAIN_SERVICE": service, "KEYKEEPER_DATA_DIR": directory.path, "KEYKEEPER_TEST_SOCKET": socket]
    }
}
