import XCTest
@testable import KeyKeeperCore

final class GrantAuthorizationPolicyTests: XCTestCase {
    private var tmpDir: URL!
    private var grantStore: GrantStore!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        grantStore = GrantStore(directory: tmpDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_曾经的_bug_nil_session下always和timed授权能通过取值校验() throws {
        try XCTContext.runActivity(named: "【曾经的 bug】nil session 下 .always/.timed grant 应能通过取值校验") { _ in
            let alwaysGrant = Grant(
                id: "always-grant",
                credentialId: "always-credential",
                duration: .always
            )
            let timedGrant = Grant(
                id: "timed-grant",
                credentialId: "timed-credential",
                duration: .timed(Date().addingTimeInterval(3600))
            )
            try grantStore.addGrant(alwaysGrant)
            try grantStore.addGrant(timedGrant)

            let matchedAlways = try GrantAuthorizationPolicy.validGrantForValueAccess(
                credentialId: "always-credential",
                sessionId: nil,
                grantStore: grantStore
            )
            let matchedTimed = try GrantAuthorizationPolicy.validGrantForValueAccess(
                credentialId: "timed-credential",
                sessionId: nil,
                grantStore: grantStore
            )

            XCTAssertEqual(matchedAlways?.id, "always-grant")
            XCTAssertEqual(matchedTimed?.id, "timed-grant")
        }
    }

    func test_曾经的_bug_nil_session下thisSession不会写随机session授权() throws {
        try XCTContext.runActivity(named: "【曾经的 bug】nil session 下选择 This session 必须拒绝而不是写随机 .session(UUID)") { _ in
            XCTAssertThrowsError(
                try GrantAuthorizationPolicy.resolveIssuedDuration(
                    requestedDuration: .session(""),
                    requestSessionId: nil
                )
            ) { error in
                XCTAssertEqual(
                    error.localizedDescription,
                    GrantAuthorizationPolicy.missingTerminalSessionMessage
                )
            }

            let resolved = try GrantAuthorizationPolicy.resolveIssuedDuration(
                requestedDuration: .session("placeholder-from-ui"),
                requestSessionId: "terminal-session"
            )
            XCTAssertEqual(resolved, .session("terminal-session"))
        }
    }

    func test_曾经的_bug_once授权预检不消费且成功发放value后才消费() throws {
        try XCTContext.runActivity(named: "【曾经的 bug】.once grant 不能在 CLI 预检阶段消费") { _ in
            let grant = Grant(
                id: "once-grant",
                credentialId: "once-credential",
                duration: .once
            )
            try grantStore.addGrant(grant)

            let preflightGrant = try GrantAuthorizationPolicy.validGrantForValueAccess(
                credentialId: "once-credential",
                sessionId: nil,
                grantStore: grantStore
            )
            XCTAssertEqual(preflightGrant?.id, "once-grant")
            XCTAssertFalse(try XCTUnwrap(grantStore.grants(for: "once-credential").first).consumed)

            try GrantAuthorizationPolicy.consumeOnceGrantAfterSuccessfulValueIfNeeded(
                preflightGrant,
                grantStore: grantStore
            )
            XCTAssertTrue(try XCTUnwrap(grantStore.grants(for: "once-credential").first).consumed)
        }
    }
}
