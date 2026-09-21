import XCTest
import KeyKeeperCore
@testable import KeyKeeperCLI

final class RunInjectionPlanTests: XCTestCase {
    private func credential(
        security: SecurityLevel = .strict,
        aliases: [String]? = nil,
        fields: [String: CredentialField]
    ) -> Credential {
        Credential(label: "Service", notes: "", links: [], fields: fields,
                   security: security, created: "2026-01-01", updated: "2026-01-01",
                   aliases: aliases)
    }

    private func mapping(_ credential: String, _ field: String, _ environment: String) -> String {
        "\(credential):\(field)\(String(UnicodeScalar(61)!))\(environment)"
    }

    // P1 合同：显式映射接受旧组名和旧字段名，但只注入调用方指定的最终变量名。
    func testExplicitTextMappingResolvesAliasesAndReplacesDefaultNames() throws {
        let meta = MetaFile(credentials: [
            "siliconflow": credential(aliases: ["siliconflow-old"], fields: [
                "key": .init(secret: true, aliases: ["api-key"]),
                "region": .init(value: "cn", secret: false),
            ]),
        ])

        let plan = try RunInjectionPlan(
            credentials: ["siliconflow"],
            environmentMappings: [
                mapping("siliconflow-old", "api-key", "SILICONFLOW_API_KEY"),
                mapping("siliconflow", "region", "SILICONFLOW_REGION"),
            ],
            fileMappings: [], prefix: "IGNORED_", meta: meta
        )

        let key = try XCTUnwrap(plan.binding(credential: "siliconflow", field: "key"))
        XCTAssertEqual(key.environmentName, "SILICONFLOW_API_KEY")
        XCTAssertEqual(key.aliasEnvironmentNames, [], "显式映射不能暗中再注入默认名或旧名")
        XCTAssertEqual(plan.binding(credential: "siliconflow", field: "region")?.environmentName,
                       "SILICONFLOW_REGION")
    }

    // P1 安全合同：映射必须在任何取值之前拒绝类型混淆、保留变量、重复字段和变量冲突。
    func testInvalidOrConflictingMappingsFailClosed() {
        let meta = MetaFile(credentials: [
            "svc": credential(fields: [
                "key": .init(secret: true),
                "other": .init(secret: true),
                "json": .init(secret: true, fileFormat: .serviceAccountJSON),
                "pending": .init(value: "unconfirmed", secret: false, setByCaller: "agent"),
            ]),
        ])
        let fileMapping = mapping("svc", "json", "SERVICE_JSON")
        let invalidEnvironmentMappings = [
            [mapping("svc", "json", "SERVICE_JSON")],
            [mapping("svc", "key", "PATH")],
            [mapping("svc", "key", "TOKEN"), mapping("svc", "key", "OTHER_TOKEN")],
            [mapping("svc", "key", "TOKEN"), mapping("svc", "other", "TOKEN")],
            [mapping("other", "key", "TOKEN")],
            [mapping("svc", "missing", "TOKEN")],
            [mapping("svc", "pending", "TOKEN")],
        ]
        for mappings in invalidEnvironmentMappings {
            XCTAssertThrowsError(try RunInjectionPlan(
                credentials: ["svc"], environmentMappings: mappings,
                fileMappings: [fileMapping], prefix: "", meta: meta
            ), mappings.joined(separator: ","))
        }

        XCTAssertThrowsError(try RunInjectionPlan(
            credentials: ["svc"],
            environmentMappings: [mapping("svc", "key", "OTHER")],
            fileMappings: [mapping("svc", "json", "KEY")],
            prefix: "", meta: meta
        ), "显式名和另一个字段的默认名冲突时必须在读值前失败")
    }

    func testFileAndTextBindingsShareOnePlan() throws {
        let meta = MetaFile(credentials: [
            "svc": credential(fields: [
                "key": .init(secret: true),
                "json": .init(secret: true, fileFormat: .serviceAccountJSON),
            ]),
        ])
        let plan = try RunInjectionPlan(
            credentials: ["svc"],
            environmentMappings: [mapping("svc", "key", "SERVICE_API_KEY")],
            fileMappings: [mapping("svc", "json", "SERVICE_CREDENTIALS")],
            prefix: "", meta: meta
        )

        XCTAssertEqual(plan.binding(credential: "svc", field: "key")?.kind, .secretText)
        XCTAssertEqual(plan.binding(credential: "svc", field: "json")?.kind, .secretFile)
        XCTAssertTrue(plan.hasFiles)
    }

    // P1 安全合同：预检只描述形状，绝不把 meta.json 中的明文值打印出来。
    func testRenderedPlanContainsNamesAndStatesButNeverValues() throws {
        let meta = MetaFile(credentials: [
            "svc": credential(fields: [
                "key": .init(secret: true),
                "region": .init(value: "plain-value-must-not-appear", secret: false),
            ]),
        ])
        let plan = try RunInjectionPlan(
            credentials: ["svc"],
            environmentMappings: [mapping("svc", "key", "SERVICE_API_KEY")],
            fileMappings: [], prefix: "", meta: meta
        )

        let output = plan.render(meta: meta, inventory: ["svc": ["key"]])
        XCTAssertTrue(output.contains("svc:key -> SERVICE_API_KEY"))
        XCTAssertTrue(output.contains("stored: yes"))
        XCTAssertTrue(output.contains("access: checked at run time (Ask Every Time)"))
        XCTAssertTrue(output.contains("svc:region -> REGION"))
        XCTAssertTrue(output.contains("access: not required"))
        XCTAssertFalse(output.contains("plain-value-must-not-appear"))
        XCTAssertTrue(output.contains("No conflicts detected."))
        XCTAssertTrue(output.contains("No secret values were read. No command was started."))
    }

    func testPlanFlagMakesCommandOptionalButNormalRunStillRequiresOne() throws {
        let command = try RunCommand.parse([
            "-c", "svc", "--plan", "--env", mapping("svc", "key", "SERVICE_API_KEY"),
        ])
        XCTAssertTrue(command.plan)
        XCTAssertEqual(command.environment, [mapping("svc", "key", "SERVICE_API_KEY")])
        XCTAssertThrowsError(try RunCommand.parse(["-c", "svc"]))
        XCTAssertThrowsError(try RunCommand.parse(["-c", "svc", "--plan", "--tty"]))
    }
}
