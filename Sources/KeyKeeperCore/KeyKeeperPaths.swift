import Foundation

public enum KeyKeeperPaths {
    public static let applicationSupportDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    )[0].appendingPathComponent("KeyKeeper", isDirectory: true)
}
