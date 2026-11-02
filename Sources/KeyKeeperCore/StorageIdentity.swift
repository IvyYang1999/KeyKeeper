import Foundation

/// A new signed App uses a new local vault; legacy tools can only modify the retained source.
/// This does not enable cloud sync. Test isolation continues to use the existing login fixture.
public enum StorageIdentity: String, Codable, Sendable {
    case legacy = "com.keykeeper.app"
    case current = "dev.keykeeper.app"

    public static let team = "ZPTA4LP594"
    public static let currentBundleIdentifier = "dev.keykeeper.app"
    public static let accessGroup = "ZPTA4LP594.dev.keykeeper.app"
    public static var runtime: Self {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment)
    }
    public static func resolve(bundleIdentifier: String?, environment: [String: String]) -> Self {
        if let service = environment["KEYKEEPER_KEYCHAIN_SERVICE"], service.hasPrefix("com.keykeeper.test."),
           environment["KEYKEEPER_DATA_DIR"]?.isEmpty == false,
           let socket = environment["KEYKEEPER_TEST_SOCKET"], socket.hasPrefix("/tmp/keykeeper-test-"),
           IPCConstants.resolveSocketPath(environment: environment) == socket { return .legacy }
        return bundleIdentifier == currentBundleIdentifier ? .current : .legacy
    }
    public var requiresBoundRequests: Bool { self == .current }
    public var servicePrefix: String { self == .current ? "dev.keykeeper." : "com.keykeeper." }
    public var credentialsService: String { servicePrefix + "credentials" }
    public var directoryName: String { self == .current ? "KeyKeeper-v2" : "KeyKeeper" }
    public var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(directoryName, isDirectory: true)
    }
}
