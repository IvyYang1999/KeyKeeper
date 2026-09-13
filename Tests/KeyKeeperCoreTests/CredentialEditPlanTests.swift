import XCTest
@testable import KeyKeeperCore

final class CredentialEditPlanTests: XCTestCase {
    func test曾经的Bug编辑时密钥留空不写存储保留Meta并更新Security() {
        XCTContext.runActivity(named: "【曾经的 bug】编辑时密钥留空") { _ in
            let existingFields = [
                "api_key": CredentialField(secret: true),
                "legacy_note": CredentialField(value: "visible", secret: false)
            ]

            let plan = CredentialEditPlan(
                inputFields: [
                    .init(name: "api_key", value: ""),
                    .init(name: "fresh_empty", value: ""),
                    .init(name: "region", value: "us-east-1")
                ],
                existingFields: existingFields,
                security: .standard
            )

            XCTAssertEqual(plan.valueWrites, [
                .init(fieldName: "region", value: "us-east-1")
            ])
            XCTAssertEqual(plan.valueDeletions, [])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key", "region"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertNil(plan.metadata.fields["api_key"]?.value)
            XCTAssertEqual(plan.metadata.security, .standard)
        }
    }

    func test曾经的Bug编辑时填新值会写存储并保留字段() {
        XCTContext.runActivity(named: "【曾经的 bug】编辑时填新值") { _ in
            let plan = CredentialEditPlan(
                inputFields: [
                    .init(name: "api_key", value: "new-secret")
                ],
                existingFields: [
                    "api_key": CredentialField(secret: true)
                ],
                security: .strict
            )

            XCTAssertEqual(plan.valueWrites, [
                .init(fieldName: "api_key", value: "new-secret")
            ])
            XCTAssertEqual(plan.valueDeletions, [])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertEqual(plan.metadata.security, .strict)
        }
    }

    func test曾经的Bug新增凭据有值正常写入空新字段跳过() {
        XCTContext.runActivity(named: "【曾经的 bug】新增凭据有值正常写入") { _ in
            let plan = CredentialEditPlan(
                inputFields: [
                    .init(name: "api_key", value: "opaque-new-value"),
                    .init(name: "unused", value: "")
                ],
                existingFields: [:],
                security: .strict
            )

            XCTAssertEqual(plan.valueWrites, [
                .init(fieldName: "api_key", value: "opaque-new-value")
            ])
            XCTAssertEqual(plan.valueDeletions, [])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertEqual(plan.metadata.security, .strict)
        }
    }

    func test删除已有Secret字段会生成Vault删除集合() {
        let plan = CredentialEditPlan(
            inputFields: [
                .init(name: "kept", value: "")
            ],
            existingFields: [
                "kept": CredentialField(secret: true),
                "removed": CredentialField(secret: true),
                "visible": CredentialField(value: "region", secret: false)
            ],
            security: .strict
        )

        XCTAssertEqual(plan.valueWrites, [])
        XCTAssertEqual(plan.valueDeletions, ["removed"])
        XCTAssertEqual(Set(plan.metadata.fields.keys), ["kept"])
    }

    /// 【曾经的 bug】2026-09-11 yyt：编辑时没先点小眼睛就改字段名，保存后值和字段一起消失。
    /// 编辑态的值是空的，旧计划按名字对账，把改名当成「删旧字段 + 新增空字段」。
    func test曾经的Bug未揭示时改字段名会把值带到新名字() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "secret-key", value: "", originalName: "Secret key")],
            existingFields: ["Secret key": CredentialField(secret: true)],
            security: .standard
        )

        XCTAssertEqual(plan.valueRenames, [.init(from: "Secret key", to: "secret-key")])
        XCTAssertEqual(plan.valueWrites, [])
        XCTAssertEqual(plan.valueDeletions, ["Secret key"], "旧名字的值要在搬走后删除")
        XCTAssertEqual(Set(plan.metadata.fields.keys), ["secret-key"])
        XCTAssertTrue(plan.metadata.fields["secret-key"]?.secret ?? false)
    }

    func test改名同时填了新值就写新值不搬旧值() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "secret-key", value: "fresh", originalName: "Secret key")],
            existingFields: ["Secret key": CredentialField(secret: true)],
            security: .standard
        )

        XCTAssertEqual(plan.valueRenames, [])
        XCTAssertEqual(plan.valueWrites, [.init(fieldName: "secret-key", value: "fresh")])
        XCTAssertEqual(plan.valueDeletions, ["Secret key"])
    }

    func test名字没变时不算改名() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "api_key", value: "", originalName: "api_key")],
            existingFields: ["api_key": CredentialField(secret: true)],
            security: .standard
        )

        XCTAssertEqual(plan.valueRenames, [])
        XCTAssertEqual(plan.valueDeletions, [])
        XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key"])
    }

    /// yyt 2026-09-11：旧名一直保留。界面上改字段名也要把旧名记进 aliases，显示名跟着走。
    func test界面改字段名会记下旧名并保留显示名() {
        let existing = ["cc": CredentialField(secret: true, displayName: "千帆 Key")]
        let moved = CredentialEditPlan(inputFields: [.init(name: "api-key", value: "", originalName: "cc")],
                                       existingFields: existing, security: .standard)
        XCTAssertEqual(moved.metadata.fields["api-key"]?.aliases, ["cc"])
        XCTAssertEqual(moved.metadata.fields["api-key"]?.displayName, "千帆 Key")
        XCTAssertEqual(moved.fieldRenames, ["cc": "api-key"])

        let rewritten = CredentialEditPlan(inputFields: [.init(name: "api-key", value: "fresh", originalName: "cc")],
                                           existingFields: existing, security: .standard)
        XCTAssertEqual(rewritten.metadata.fields["api-key"]?.aliases, ["cc"], "填了新值也是同一个字段改了名")
        XCTAssertEqual(rewritten.metadata.fields["api-key"]?.displayName, "千帆 Key")
        XCTAssertNil(rewritten.metadata.fields["api-key"]?.fileFormat)

        let same = CredentialEditPlan(inputFields: [.init(name: "cc", value: "fresh", originalName: "cc")],
                                      existingFields: existing, security: .standard)
        XCTAssertNil(same.metadata.fields["cc"]?.aliases)
        XCTAssertEqual(same.metadata.fields["cc"]?.displayName, "千帆 Key", "只改值不丢显示名")
    }

    /// 非机密字段：值明文写在 meta.json 里，不进钥匙串。
    func test非机密字段的值写进Meta不写钥匙串() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "apple-id", value: "a@b.invalid", isSecret: false)],
            existingFields: [:],
            security: .standard
        )
        XCTAssertEqual(plan.valueWrites, [], "非机密不写钥匙串")
        XCTAssertEqual(plan.metadata.fields["apple-id"]?.value, "a@b.invalid")
        XCTAssertEqual(plan.metadata.fields["apple-id"]?.secret, false)
    }

    /// 机密 → 非机密：值要搬进 meta 明文，钥匙串里的旧值随后删除。
    func test机密转非机密时值搬进Meta并删掉钥匙串里的() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "token", value: "moved-value", originalName: "token", isSecret: false)],
            existingFields: ["token": CredentialField(secret: true, displayName: "Token")],
            security: .standard
        )
        XCTAssertEqual(plan.metadata.fields["token"]?.value, "moved-value")
        XCTAssertEqual(plan.metadata.fields["token"]?.secret, false)
        XCTAssertEqual(plan.metadata.fields["token"]?.displayName, "Token", "显示名不丢")
        XCTAssertEqual(plan.valueDeletions, ["token"], "钥匙串里的旧值要删掉，不能留孤儿")
        XCTAssertEqual(plan.valueWrites, [])
    }

    /// 【安全红线】转非机密却没拿到值时，绝不能删钥匙串、也不能写一个空的明文字段——
    /// 那等于把值弄丢。这种情况保持机密不动。
    func test转非机密但没有值时保持机密不动() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "token", value: "", originalName: "token", isSecret: false)],
            existingFields: ["token": CredentialField(secret: true)],
            security: .standard
        )
        XCTAssertEqual(plan.metadata.fields["token"]?.secret, true)
        XCTAssertNil(plan.metadata.fields["token"]?.value)
        XCTAssertEqual(plan.valueDeletions, [])
    }

    /// 非机密 → 机密：值从 meta 搬进钥匙串，meta 里不再留明文。
    func test非机密转机密时值写进钥匙串并从Meta清掉() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "apple-id", value: "a@b.invalid", originalName: "apple-id", isSecret: true)],
            existingFields: ["apple-id": CredentialField(value: "a@b.invalid", secret: false)],
            security: .standard
        )
        XCTAssertEqual(plan.valueWrites, [.init(fieldName: "apple-id", value: "a@b.invalid")])
        XCTAssertEqual(plan.metadata.fields["apple-id"]?.secret, true)
        XCTAssertNil(plan.metadata.fields["apple-id"]?.value, "明文不能留在 meta 里")
    }

    /// 非机密字段改名：明文值跟着走，不需要动钥匙串。
    func test非机密字段改名值跟着走() {
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "account", value: "a@b.invalid", originalName: "apple-id", isSecret: false)],
            existingFields: ["apple-id": CredentialField(value: "a@b.invalid", secret: false)],
            security: .standard
        )
        XCTAssertEqual(plan.metadata.fields["account"]?.value, "a@b.invalid")
        XCTAssertEqual(plan.metadata.fields["account"]?.aliases, ["apple-id"])
        XCTAssertEqual(plan.valueRenames, [], "非机密不涉及钥匙串搬值")
        XCTAssertEqual(plan.valueDeletions, [])
        XCTAssertEqual(plan.fieldRenames, ["apple-id": "account"])
    }
}
