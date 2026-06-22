import XCTest
@testable import KeyKeeperCore

final class CredentialEditPlanTests: XCTestCase {
    func test曾经的Bug编辑时密钥留空不写Keychain保留Meta并更新Security() {
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

            XCTAssertEqual(plan.keychainWrites, [
                .init(fieldName: "region", value: "us-east-1")
            ])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key", "region"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertNil(plan.metadata.fields["api_key"]?.value)
            XCTAssertEqual(plan.metadata.security, .standard)
        }
    }

    func test曾经的Bug编辑时填新值会写Keychain并保留字段() {
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

            XCTAssertEqual(plan.keychainWrites, [
                .init(fieldName: "api_key", value: "new-secret")
            ])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertEqual(plan.metadata.security, .strict)
        }
    }

    func test曾经的Bug新增凭据有值正常写入空新字段跳过() {
        XCTContext.runActivity(named: "【曾经的 bug】新增凭据有值正常写入") { _ in
            let plan = CredentialEditPlan(
                inputFields: [
                    .init(name: "api_key", value: "sk-new"),
                    .init(name: "unused", value: "")
                ],
                existingFields: [:],
                security: .strict
            )

            XCTAssertEqual(plan.keychainWrites, [
                .init(fieldName: "api_key", value: "sk-new")
            ])
            XCTAssertEqual(Set(plan.metadata.fields.keys), ["api_key"])
            XCTAssertTrue(plan.metadata.fields["api_key"]?.secret ?? false)
            XCTAssertEqual(plan.metadata.security, .strict)
        }
    }
}
