import XCTest
@testable import KeyKeeperCore

final class IPCErrorMessageTests: XCTestCase {
    func test每个错误都告诉用户下一步() {
        let cases: [(IPCError, String)] = [
            (.vaultLocked, "Open the KeyKeeper app"),
            (.appNotRunning, "Open KeyKeeper from Applications"),
            (.noAuthorization("No valid grant"), "Background OK"),
            (.noAuthorization(nil), "keykeeper grants list"),
            (.denied("User denied"), "Authorize"),
            (.timeout, "Run the command again"),
            (.vaultReadFailed(nil), "KeyKeeper app"),
            (.appVersionTooOld, "Update the app"),
            (.connectionFailed, "Open KeyKeeper from Applications"),
        ]
        for (error, hint) in cases {
            XCTAssertTrue(
                error.localizedDescription.contains(hint),
                "\(error) should mention '\(hint)', got: \(error.localizedDescription)"
            )
        }
    }

    func test附加信息为空时不留悬挂冒号() {
        XCTAssertFalse(IPCError.noAuthorization(nil).localizedDescription.contains(": ."))
        XCTAssertFalse(IPCError.denied("").localizedDescription.contains("denied:"))
        XCTAssertTrue(IPCError.denied("User denied").localizedDescription.contains("denied: User denied"))
    }
}
