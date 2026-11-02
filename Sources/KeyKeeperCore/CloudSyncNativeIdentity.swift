import Foundation
import Security

public struct CloudSyncNativeIdentity: Sendable {
    public static let container = "iCloud.dev.keykeeper.app"
    public let environment: String
    public static func current() throws -> Self {
        do { try IdentityMigrationSignature.current(.current) }
        catch { throw CloudSyncError.setupRequired }
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { throw CloudSyncError.setupRequired }
        return try validate(dictionary, bundleID: Bundle.main.bundleIdentifier,
            profilePresent: FileManager.default.fileExists(atPath:
                Bundle.main.bundleURL.appendingPathComponent("Contents/embedded.provisionprofile").path))
    }
    static func validate(_ info: [String: Any], bundleID: String?, profilePresent: Bool) throws -> Self {
        guard bundleID == StorageIdentity.currentBundleIdentifier, profilePresent,
              info[kSecCodeInfoIdentifier as String] as? String == StorageIdentity.currentBundleIdentifier,
              info[kSecCodeInfoTeamIdentifier as String] as? String == StorageIdentity.team,
              let ent = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              ent["com.apple.application-identifier"] as? String == StorageIdentity.accessGroup,
              ent["com.apple.developer.team-identifier"] as? String == StorageIdentity.team,
              ent["keychain-access-groups"] as? [String] == [StorageIdentity.accessGroup],
              ent["com.apple.developer.icloud-container-identifiers"] as? [String] == [container],
              ent["com.apple.developer.icloud-services"] as? [String] == ["CloudKit"],
              let env = ent["com.apple.developer.icloud-container-environment"] as? String,
              ["Development", "Production"].contains(env) else { throw CloudSyncError.setupRequired }
        return Self(environment: env)
    }
}
