import Foundation
import XCTest
import KeyKeeperCore
@testable import KeyKeeperCLI

final class CLIRevisionClientTests: XCTestCase {
    func testSnapshotConsumerRejectsMissingAndMismatchedRevision() throws {
        let metadata = MetaFile()
        XCTAssertThrowsError(try IPCClient.decodeSnapshotResponse(.vaultSnapshot(.init(success: true, metadata: metadata))))
        let wrong = VaultRevision(instanceID: UUID(), epoch: 1, metadataDigest: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try IPCClient.decodeSnapshotResponse(.vaultSnapshot(.init(success: true,
            metadata: metadata, revision: wrong)))) {
            XCTAssertEqual($0 as? VaultRevisionError, .stale)
        }
    }

    func testRevisionErrorTakesPriorityOverSuccessOrAuthorizationRefusal() {
        for (code, expected) in [(VaultRevisionErrorCode.stale, VaultRevisionError.stale),
                                 (.required, .required), (.unavailable, .unavailable)] {
            for success in [false, true] {
                XCTAssertThrowsError(try IPCClient.decodeValueResponse(.init(success: success,
                    value: success ? "must-not-escape" : nil, errorCode: .noAuthorization, revisionError: code))) {
                    XCTAssertEqual($0 as? VaultRevisionError, expected)
                }
            }
        }
    }

    func testOldAppSnapshotResponseIsAnUpgradeFailure() {
        XCTAssertThrowsError(try IPCClient.decodeSnapshotResponse(.value(.init(success: false, errorCode: .invalidRequest)))) {
            guard case IPCError.appVersionTooOld = $0 else { return XCTFail("Expected upgrade failure") }
        }
    }
}
