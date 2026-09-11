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
}
