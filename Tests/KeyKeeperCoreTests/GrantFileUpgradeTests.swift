import XCTest
@testable import KeyKeeperCore
import KeyKeeperTestSupport

/// 【独立审计第二轮 · critical，2026-09-13 23 点在 yyt 本机真实发生】两份授权文件共用一把签名密钥。升级后首次启动，
/// 先清理 grants.json 时建出密钥，紧接着清理 service-grants.json——密钥已在、文件未签——被判篡改、换成空文件：
/// 后台授权与访问记录全部清空，模式被改成「先问我」。这里跑的就是 App 真实的接线。
final class GrantFileUpgradeTests: XCTestCase {
    private var dir: URL!
    private var keychain: FakeKeychain!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("grant-upgrade-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        keychain = FakeKeychain()
        let chain = keychain!
        GrantFileIntegrity.configureAppDefaults { chain.io($0) }
    }

    override func tearDownWithError() throws {
        GrantFileIntegrity.grantsDefault = nil
        GrantFileIntegrity.serviceGrantsDefault = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeLegacyFiles() throws {
        let legacyGrants = GrantFile(grants: [Grant(credentialId: "c", duration: .always, subjectFingerprint: "unsigned:path=a")])
        let legacyService = ServiceGrantFile(mode: .permissive, grants: [
            ServiceGrant(credentialId: "c", subjectFingerprint: "unsigned:path=a", subjectDisplayName: "x", fields: ["f"], duration: .always)
        ])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(legacyGrants).write(to: dir.appendingPathComponent("grants.json"))
        try encoder.encode(legacyService).write(to: dir.appendingPathComponent("service-grants.json"))
    }

    func test升级后首次启动两份旧文件都被收养() throws {
        try writeLegacyFiles()
        let grants = GrantStore(directory: dir), service = ServiceGrantStore(directory: dir)
        try grants.pruneExpired()       // the app does these two, in this order, at every launch
        try service.pruneExpired()
        XCTAssertNotNil(try grants.findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"))
        XCTAssertNotNil(try service.findValidGrant(credentialId: "c", subjectFingerprint: "unsigned:path=a", fieldName: "f"))
        XCTAssertEqual(try service.authorizationMode(), .permissive, "用户选的模式不能被悄悄改掉")
    }

    func test开发版用授权密钥签过的service文件照样收养() throws {
        try writeLegacyFiles()
        // What the broken build left behind: service-grants.json signed with the grants key.
        let shared = GrantFileIntegrity(io: keychain.io(IntegrityKeyNames.service(GrantFileIntegrity.grantsKeyName)))
        try ServiceGrantStore(directory: dir, integrity: shared).setAuthorizationMode(.enforced)
        let service = ServiceGrantStore(directory: dir)
        XCTAssertEqual(try service.authorizationMode(), .enforced)
        XCTAssertNotNil(try service.findValidGrant(credentialId: "c", subjectFingerprint: "unsigned:path=a", fieldName: "f"))
    }

    func test钥匙串一时读不出来不会清空授权() throws {
        try writeLegacyFiles()
        try GrantStore(directory: dir).pruneExpired()     // signed from here on
        let keyName = IntegrityKeyNames.service(GrantFileIntegrity.grantsKeyName)
        keychain.failNextReads(of: keyName, count: 1)
        let chain = keychain!
        GrantFileIntegrity.configureAppDefaults { chain.io($0) }   // fresh instances, nothing cached
        XCTAssertThrowsError(try GrantStore(directory: dir).pruneExpired(), "读不出密钥就别动文件")
        XCTAssertNotNil(try GrantStore(directory: dir).findValidGrant(credentialId: "c", sessionId: nil, fingerprint: "unsigned:path=a"))
    }

    func test隔离实例用自己的完整性密钥名() {
        let isolated = ["KEYKEEPER_KEYCHAIN_SERVICE": "com.keykeeper.test.abc", "KEYKEEPER_DATA_DIR": "/tmp/kk"]
        XCTAssertEqual(IntegrityKeyNames.service("grants-mac", environment: isolated), "com.keykeeper.test.abc.grants-mac")
        XCTAssertEqual(IntegrityKeyNames.service("grants-mac", environment: [:]), "com.keykeeper.grants-mac")
        XCTAssertEqual(IntegrityKeyNames.service("grants-mac", environment: ["KEYKEEPER_KEYCHAIN_SERVICE": "com.other"]),
                       "com.keykeeper.grants-mac")
    }
}
