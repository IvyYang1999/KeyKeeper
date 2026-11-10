import XCTest
import CloudKit
@testable import KeyKeeperCore

/// 【曾经的 bug】2026-11-08：刚唤醒、刚登录或断网时，iCloud 一时答不上「你是谁」，也被当成「账号已更改」，
/// 而且这个暂停会存下来，重启 App 也不消。Only a missing or restricted account, or an answer that
/// is not a network-class failure, is an account problem. None of these produce a binding, so
/// nothing is read or written either way; this decides which pause and its wording.
final class CloudKitAccountErrorTests: XCTestCase {
    func test曾经的BugICloud一时答不上来不算换了账号() {
        XCTAssertNil(CloudKitSyncTransport.accountStatusError(.available))
        XCTAssertEqual(CloudKitSyncTransport.accountStatusError(.couldNotDetermine), .unavailable)
        XCTAssertEqual(CloudKitSyncTransport.accountStatusError(.temporarilyUnavailable), .unavailable)
        XCTAssertEqual(CloudKitSyncTransport.accountStatusError(.noAccount), .accountChanged)
        XCTAssertEqual(CloudKitSyncTransport.accountStatusError(.restricted), .accountChanged)

        let transient: [CKError.Code] = [.networkUnavailable, .networkFailure, .serviceUnavailable,
                                         .requestRateLimited, .zoneBusy, .accountTemporarilyUnavailable]
        for code in transient {
            XCTAssertEqual(CloudKitSyncTransport.userRecordError(CKError(code)), .unavailable, "\(code.rawValue)")
        }
        let account: [Error?] = [nil, CKError(.notAuthenticated), CKError(.permissionFailure),
                                 CKError(.badContainer), NSError(domain: "synthetic", code: 1)]
        for error in account {
            XCTAssertEqual(CloudKitSyncTransport.userRecordError(error), .accountChanged)
        }
    }
}
