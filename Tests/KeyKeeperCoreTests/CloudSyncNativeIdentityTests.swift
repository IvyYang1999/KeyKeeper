import XCTest
import Security
@testable import KeyKeeperCore

final class CloudSyncNativeIdentityTests: XCTestCase {
    private var entitlements: [String: Any] { [
        "com.apple.application-identifier": StorageIdentity.accessGroup,
        "com.apple.developer.team-identifier": StorageIdentity.team,
        "keychain-access-groups": [StorageIdentity.accessGroup],
        "com.apple.developer.icloud-container-identifiers": [CloudSyncNativeIdentity.container],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.developer.icloud-container-environment": "Production"
    ] }
    private func info(_ ent: [String: Any]) -> [String: Any] { [
        kSecCodeInfoIdentifier as String: StorageIdentity.currentBundleIdentifier,
        kSecCodeInfoTeamIdentifier as String: StorageIdentity.team,
        kSecCodeInfoEntitlementsDict as String: ent
    ] }
    func testOnlyExactAppGroupContainerAndSupportedEnvironmentAreAdmitted() throws {
        XCTAssertEqual(try CloudSyncNativeIdentity.validate(info(entitlements),
            bundleID: StorageIdentity.currentBundleIdentifier, profilePresent: true).environment, "Production")
        for key in entitlements.keys {
            var changed = entitlements; changed.removeValue(forKey: key)
            XCTAssertThrowsError(try CloudSyncNativeIdentity.validate(info(changed),
                bundleID: StorageIdentity.currentBundleIdentifier, profilePresent: true), key)
        }
        var extra = entitlements
        extra["keychain-access-groups"] = [StorageIdentity.accessGroup, "other"]
        XCTAssertThrowsError(try CloudSyncNativeIdentity.validate(info(extra),
            bundleID: StorageIdentity.currentBundleIdentifier, profilePresent: true))
        XCTAssertThrowsError(try CloudSyncNativeIdentity.validate(info(entitlements),
            bundleID: StorageIdentity.legacy.rawValue, profilePresent: true))
        XCTAssertThrowsError(try CloudSyncNativeIdentity.validate(info(entitlements),
            bundleID: StorageIdentity.currentBundleIdentifier, profilePresent: false))
    }
}
