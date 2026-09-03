import Foundation

public enum KeyKeeperPaths {
    /// Environment override for the data directory. Used by automated acceptance runs
    /// so a test build never touches the user's real vault, and handy for portable installs.
    public static let dataDirectoryEnvironmentKey = "KEYKEEPER_DATA_DIR"

    public static let applicationSupportDirectory: URL = resolveApplicationSupportDirectory(
        environment: ProcessInfo.processInfo.environment
    )

    static func resolveApplicationSupportDirectory(environment: [String: String]) -> URL {
        if let override = environment[dataDirectoryEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("KeyKeeper", isDirectory: true)
    }
}
