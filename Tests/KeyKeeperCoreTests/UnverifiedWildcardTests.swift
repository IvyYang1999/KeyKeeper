import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 【独立审计 2026-09-13】「未核实的身份匹配不到授权」只加在了 GrantStore 上。ServiceGrantStore
/// 和登录态授权照样按字符串相等匹配——而 `unverified:no-code-object` 这类指纹是**常量**，
/// 攻击者还能主动掉进这一档（拷一份二进制、跑起来、删掉）。两个都掉进去的进程，指纹一模
/// 一样，互相就能蹭对方的授权。未核实就是未核实，哪一种授权都不能认它。
final class UnverifiedWildcardTests: XCTestCase {
    func testService授权不认未核实的身份() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unverified-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ServiceGrantStore(directory: dir)
        let fingerprint = CallerSubject.unverifiedPrefix + "no-code-object"
        try store.addGrant(ServiceGrant(credentialId: "openai", subjectFingerprint: fingerprint,
                                        subjectDisplayName: "?", fields: ["api-key"], duration: .always))
        XCTAssertNil(try store.findValidGrant(credentialId: "openai", subjectFingerprint: fingerprint, fieldName: "api-key"))
    }

    func test登录态授权不认未核实的身份() throws {
        let io = FakeKeychainIO()
        let store = BrowserSessionStore(io: io, marker: WildcardMarker())
        let id = UUID().uuidString
        _ = try store.save(BrowserSessionImport(id: id, origin: "https://example.com", label: "S", cookies: [
            .init(name: "s", value: "synthetic", domain: "example.com", hostOnly: true, path: "/",
                  secure: true, httpOnly: true, sameSite: "lax", expirationDate: nil)]))
        let fingerprint = CallerSubject.unverifiedPrefix + "no-code-object"
        try store.addGrant(.init(sessionId: id, subjectFingerprint: fingerprint, subjectDisplayName: "?", duration: .always))
        XCTAssertNil(try store.validGrant(sessionId: id, fingerprint: fingerprint))
    }

    /// 发授权的时候就不该把未核实的身份记成主人。
    func test不给未核实的身份发可复用的授权() {
        XCTAssertFalse(GrantIssuancePolicy.mayRemember(subjectFingerprint: CallerSubject.unverifiedPrefix + "unlocatable"))
        XCTAssertTrue(GrantIssuancePolicy.mayRemember(subjectFingerprint: "unsigned:path=abc"))
        XCTAssertTrue(GrantIssuancePolicy.mayRemember(subjectFingerprint: "app:team=A:bundle=b:signing=c"))
    }
}

private final class WildcardMarker: BrowserSessionMarker {
    var exists = false
    func wasCreated() throws -> Bool { exists }
    func markCreated() throws { exists = true }
}
