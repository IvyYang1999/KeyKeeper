import XCTest
@testable import KeyKeeperCore

/// 【独立审计第二轮】「仅这一次」在读完第一个字段后就被用掉；一条凭据有几个机密字段，run 就弹几次窗。
final class OnceGrantAcrossFieldsTests: XCTestCase {
    private var dir: URL!
    private var store: GrantStore!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("once-fields-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = GrantStore(directory: dir)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func test一次批准覆盖这次run要读的所有字段() throws {
        let grant = Grant(credentialId: "c", duration: .once, subjectFingerprint: "unsigned:path=a", onceFieldsRemaining: ["a", "b"])
        try store.addGrant(grant)
        try GrantAuthorizationPolicy.consumeOnceGrantAfterSuccessfulValueIfNeeded(grant, fieldName: "a", grantStore: store)
        XCTAssertNotNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"), "第二个字段还没读")
        try GrantAuthorizationPolicy.consumeOnceGrantAfterSuccessfulValueIfNeeded(grant, fieldName: "b", grantStore: store)
        XCTAssertNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"), "都读完就用掉了")
    }

    func test没读完的字段过两分钟也失效() throws {
        let grant = Grant(credentialId: "c", duration: .once, createdAt: Date().addingTimeInterval(-(GrantStore.onceWindow + 60)),
                          subjectFingerprint: "unsigned:path=a", onceFieldsRemaining: ["a", "b"])
        try store.addGrant(grant)
        XCTAssertNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"))
    }

    func test没有字段记录的旧批准读一次就用掉() throws {
        let grant = Grant(credentialId: "c", duration: .once, subjectFingerprint: "unsigned:path=a")
        try store.addGrant(grant)
        try GrantAuthorizationPolicy.consumeOnceGrantAfterSuccessfulValueIfNeeded(grant, fieldName: "a", grantStore: store)
        XCTAssertNil(try store.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"))
    }
}
