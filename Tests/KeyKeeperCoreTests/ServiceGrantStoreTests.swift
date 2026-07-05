import XCTest
@testable import KeyKeeperCore

final class ServiceGrantStoreTests: XCTestCase {
    private var tmpDir: URL!
    private var store: ServiceGrantStore!
    private var caller: CallerIdentity!

    override func setUp() {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = ServiceGrantStore(directory: tmpDir)
        caller = CallerIdentity(
            peerPID: 123,
            subject: CallerSubject(
                kind: .app,
                fingerprint: "app:team=TEAM:bundle=com.example.App:signing=com.example.App",
                displayName: "com.example.App",
                detail: "team TEAM"
            )
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_默认宽松模式未命中allowlist也放行并记录审计() throws {
        try XCTContext.runActivity(named: "兼容红线：首次升级后 standard 凭据默认不能拦截 cron/插件调用") { _ in
            let decision = try ServiceAuthorizationPolicy.decisionForValueAccess(
                credential: standardCredential(),
                credentialId: "cron-api",
                fieldName: "key",
                caller: caller,
                serviceGrantStore: store
            )

            XCTAssertEqual(decision, .allowed(nil))
            let events = try store.auditEvents()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.mode, .permissive)
            XCTAssertEqual(events.first?.decision, "allowed_without_grant")
        }
    }

    func test_强制模式standard未命中allowlist要求弹窗授权() throws {
        try XCTContext.runActivity(named: "强制模式下 standard 服务调用方必须命中 allowlist") { _ in
            try store.setAuthorizationMode(.enforced)

            let decision = try ServiceAuthorizationPolicy.decisionForValueAccess(
                credential: standardCredential(),
                credentialId: "cron-api",
                fieldName: "key",
                caller: caller,
                serviceGrantStore: store
            )

            XCTAssertEqual(decision, .promptRequired)
            let events = try store.auditEvents()
            XCTAssertEqual(events.count, 1)
            XCTAssertEqual(events.first?.mode, .enforced)
            XCTAssertEqual(events.first?.decision, "prompt_required")
        }
    }

    func test_命中服务grant后放行并按字段消费once授权() throws {
        try XCTContext.runActivity(named: "once 服务授权覆盖本次请求字段集合，每个字段成功取值后消费") { _ in
            let grant = ServiceGrant(
                id: "grant-1",
                credentialId: "cron-api",
                subjectFingerprint: caller.subjectFingerprint,
                subjectDisplayName: caller.displayName,
                fields: ["key", "secret"],
                duration: .once
            )
            try store.addGrant(grant)

            let first = try ServiceAuthorizationPolicy.decisionForValueAccess(
                credential: standardCredential(),
                credentialId: "cron-api",
                fieldName: "key",
                caller: caller,
                serviceGrantStore: store
            )
            guard case .allowed(let matchedGrant?) = first else {
                XCTFail("expected matching service grant")
                return
            }
            XCTAssertEqual(matchedGrant.id, grant.id)
            XCTAssertEqual(matchedGrant.fields, grant.fields)
            XCTAssertEqual(matchedGrant.subjectFingerprint, grant.subjectFingerprint)

            try store.noteSuccessfulUse(grantId: "grant-1", fieldName: "key")
            XCTAssertNotNil(try store.findValidGrant(
                credentialId: "cron-api",
                subjectFingerprint: caller.subjectFingerprint,
                fieldName: "secret"
            ))
            XCTAssertNil(try store.findValidGrant(
                credentialId: "cron-api",
                subjectFingerprint: caller.subjectFingerprint,
                fieldName: "key"
            ))

            try store.noteSuccessfulUse(grantId: "grant-1", fieldName: "secret")
            XCTAssertTrue(try store.grants().isEmpty)
        }
    }

    func test_strict凭据不受服务allowlist拦截() throws {
        try XCTContext.runActivity(named: "strict 仍走原 session grant 流程，service gate 只管 standard") { _ in
            try store.setAuthorizationMode(.enforced)
            var credential = standardCredential()
            credential.security = .strict

            let decision = try ServiceAuthorizationPolicy.decisionForValueAccess(
                credential: credential,
                credentialId: "strict-api",
                fieldName: "key",
                caller: caller,
                serviceGrantStore: store
            )

            XCTAssertEqual(decision, .allowed(nil))
            XCTAssertTrue(try store.auditEvents().isEmpty)
        }
    }

    private func standardCredential() -> Credential {
        Credential(
            label: "Cron API",
            notes: "",
            links: [],
            fields: ["key": CredentialField(secret: true)],
            security: .standard,
            created: "2026-07-04",
            updated: "2026-07-04"
        )
    }
}
