import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

/// 非机密字段（邮箱、账号 ID、区域这类）明文存在 meta.json 里，不进钥匙串。
/// `run` 也要注入它们，而且不该为它们打扰人。
final class NonSecretInjectionTests: XCTestCase {
    private func credential(_ fields: [String: CredentialField], security: SecurityLevel = .standard) -> Credential {
        Credential(label: "Notary", notes: "", links: [], fields: fields, security: security,
                   created: "2026-09-13", updated: "2026-09-13")
    }

    func test非机密字段也注入环境变量() {
        let cred = credential([
            "apple-id": CredentialField(value: "someone@example.invalid", secret: false),
            "apple-team-id": CredentialField(value: "ZPTA4LP594", secret: false),
            "apple-app-specific-password": CredentialField(secret: true),
        ])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: cred, prefix: ""),
                       ["APPLE_ID": "someone@example.invalid", "APPLE_TEAM_ID": "ZPTA4LP594"])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: cred, prefix: "K_"),
                       ["K_APPLE_ID": "someone@example.invalid", "K_APPLE_TEAM_ID": "ZPTA4LP594"])
    }

    func test空值的非机密字段跳过() {
        let cred = credential([
            "region": CredentialField(value: "", secret: false),
            "zone": CredentialField(value: nil, secret: false),
            "id": CredentialField(value: "x", secret: false),
        ])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: cred, prefix: ""), ["ID": "x"])
    }

    /// 改过名的非机密字段，旧的环境变量名也要继续注入（和机密字段一个规矩）。
    func test非机密字段的旧名也注入() {
        let cred = credential([
            "apple-id": CredentialField(value: "a@b.invalid", secret: false, aliases: ["APPLE ID"]),
        ])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: cred, prefix: ""),
                       ["APPLE_ID": "a@b.invalid"], "新旧名规整后是同一个变量名，只留一个")

        let renamed = credential([
            "account": CredentialField(value: "a@b.invalid", secret: false, aliases: ["apple-id"]),
        ])
        XCTAssertEqual(renamed.environmentNames(forField: "account"), ["ACCOUNT", "APPLE_ID"])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: renamed, prefix: ""),
                       ["ACCOUNT": "a@b.invalid", "APPLE_ID": "a@b.invalid"])
    }

    /// 只有真要读机密值时才需要授权。一条「每次询问」的凭据如果只剩非机密字段，
    /// 注入它们不该弹窗——明文本来就躺在 meta.json 里，弹窗换不来任何安全。
    func test只有要读机密值才需要授权() {
        let onlyPlain = credential(["apple-id": CredentialField(value: "a@b.invalid", secret: false)], security: .strict)
        XCTAssertFalse(RunCommand.requiresAuthorization(for: onlyPlain))

        let withSecret = credential([
            "apple-id": CredentialField(value: "a@b.invalid", secret: false),
            "password": CredentialField(secret: true),
        ], security: .strict)
        XCTAssertTrue(RunCommand.requiresAuthorization(for: withSecret))

        let standard = credential(["password": CredentialField(secret: true)], security: .standard)
        XCTAssertFalse(RunCommand.requiresAuthorization(for: standard), "standard 走的是后台授权那条路")
    }

    /// 非机密值不是秘密，不进脱敏表——否则子进程输出里所有出现邮箱的地方都会被打码。
    func test非机密值不参与输出脱敏() {
        let cred = credential([
            "apple-id": CredentialField(value: "a@b.invalid", secret: false),
            "password": CredentialField(secret: true),
        ])
        XCTAssertEqual(cred.fields.filter { !$0.value.secret }.compactMap { $0.value.value }, ["a@b.invalid"])
        XCTAssertTrue(RunCommand.nonSecretEnvironment(for: cred, prefix: "").values.allSatisfy { !$0.isEmpty })
    }

    /// 明文字段的**旧名**只是尽力而为：谁都没占才填，撞上任何现名（包括机密字段的现名）
    /// 就安静让位。原来旧名和现名一样被当成硬占用，于是「明文字段的旧名 == 机密字段的现名」
    /// 会让整条命令直接失败，而提示里建议的 --prefix 对两边同时生效，根本解不开。
    func test明文字段的旧名撞上机密字段的现名时安静让位() throws {
        let cred = credential([
            // account 改名前叫 apple-id，而现在另有一个机密字段就叫 apple-id
            "account": CredentialField(value: "a@b.invalid", secret: false, aliases: ["apple-id"]),
            "apple-id": CredentialField(secret: true),
        ])
        var injected: [String: String] = [:]
        var aliases: [String: String] = [:]
        try RunCommand.mergePlainFields(of: cred, prefix: "", into: &injected, aliases: &aliases)

        XCTAssertEqual(injected, ["ACCOUNT": "a@b.invalid"], "只有现名是硬占用")
        XCTAssertEqual(aliases, ["APPLE_ID": "a@b.invalid"], "旧名退到低优先级，等机密值来占")
    }

    /// 两个明文字段的**现名**撞在一起才是真错误，要报出来。
    func test两个明文字段的现名撞车仍然报错() {
        let cred = credential(["api-key": CredentialField(value: "x", secret: false)])
        var injected = ["API_KEY": "别的值"]
        var aliases: [String: String] = [:]
        XCTAssertThrowsError(try RunCommand.mergePlainFields(of: cred, prefix: "", into: &injected, aliases: &aliases))
    }
}

extension NonSecretInjectionTests {
    /// 【独立审计 2026-09-14】调用方经命令行写的明文值，人没确认之前 `run` 不注入，并在 stderr 说明。
    func test待确认的明文字段不注入并说明() {
        let cred = credential([
            "openai-base-url": CredentialField(value: "https://evil.example", secret: false, setByCaller: "codex"),
            "region": CredentialField(value: "us", secret: false),
            "api-key": CredentialField(secret: true),
        ])
        XCTAssertEqual(RunCommand.nonSecretEnvironment(for: cred, prefix: ""), ["REGION": "us"])
        XCTAssertEqual(RunCommand.nonSecretCurrentNames(for: cred, prefix: ""), ["REGION"])
        let note = RunCommand.unconfirmedPlainNote(credentialId: "openai", credential: cred)!
        XCTAssertTrue(note.contains("openai-base-url") && note.contains("codex") && note.contains("KeyKeeper"), note)
        XCTAssertNil(RunCommand.unconfirmedPlainNote(credentialId: "x", credential: credential(["region": CredentialField(value: "us", secret: false)])))
    }
}
