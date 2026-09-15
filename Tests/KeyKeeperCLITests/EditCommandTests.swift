import XCTest
@testable import KeyKeeperCLI
import KeyKeeperCore

/// `keykeeper edit`：Agent 可以不弹窗地改名字和备注；旧名在 run / get / --file 里一直能用。
final class EditCommandTests: XCTestCase {
    func test命令行参数变成一次编辑() throws {
        let command = try EditCommand.parse(["百度千帆", "--group-id", "baidu-qianfan", "--title", "百度千帆 · 学术",
                                             "--rename-field", "cc=api-key", "--field-label", "api-key=API Key (千帆)",
                                             "--notes", "论文检索=学术"])
        let request = try command.request()
        XCTAssertEqual(request.groupId, "百度千帆")
        XCTAssertEqual(request.edit, MetadataEdit(newGroupId: "baidu-qianfan", title: "百度千帆 · 学术", notes: "论文检索=学术",
                                                  fieldRenames: ["cc": "api-key"], fieldDisplayNames: ["api-key": "API Key (千帆)"]))
        XCTAssertThrowsError(try EditCommand.parse(["x", "--rename-field", "no-equals-sign"]).request())
        XCTAssertThrowsError(try EditCommand.parse(["x"]).request(), "什么都不改就报错")
        XCTAssertTrue(IPCLaunchPolicy.shouldLaunchApp(for: .metadataEdit(request)))
        let decoded = try JSONDecoder().decode(IPCRequest.self, from: JSONEncoder().encode(IPCRequest.metadataEdit(request)))
        guard case .metadataEdit(let roundTrip) = decoded else { return XCTFail("wrong type") }
        XCTAssertEqual(roundTrip, request)
    }

    /// 明文字段可以用 --set/--unset 直接写，机密字段这条路碰不到。
    func test绑定服务商参数() throws {
        XCTAssertEqual(try EditCommand.parse(["openai", "--provider", "gpt"]).request().edit.provider, "gpt")
        XCTAssertEqual(try EditCommand.parse(["openai", "--provider", "none"]).request().edit.provider, "none")
        let text = EditCommand.report(.init(success: true, groupId: "openai", changes: [.providerChanged(from: nil, to: "openai")]))
        XCTAssertTrue(text.contains("provider openai"), text)
    }

    func test可以写与删明文字段() throws {
        let command = try EditCommand.parse(["apple-notary",
                                             "--set", "apple-id=someone@example.invalid",
                                             "--set", "apple-team-id=ZPTA4LP594",
                                             "--unset", "region"])
        let request = try command.request()
        XCTAssertEqual(request.edit.plainFields["apple-id"], "someone@example.invalid")
        XCTAssertEqual(request.edit.plainFields["apple-team-id"], "ZPTA4LP594")
        XCTAssertEqual(request.edit.plainFields["region"], String?.none)
        XCTAssertThrowsError(try EditCommand.parse(["x", "--set", "no-equals"]).request())
    }

    func test写了明文字段就提醒要人确认() {
        let text = EditCommand.report(.init(success: true, groupId: "openai",
                                            changes: [.plainFieldSet(field: "openai-base-url", value: "https://x")]))
        XCTAssertTrue(text.contains("not injected") && text.contains("confirm"), text)
        let renameOnly = EditCommand.report(.init(success: true, groupId: "openai", changes: [.plainFieldRemoved(field: "region")]))
        XCTAssertFalse(renameOnly.contains("not injected"))
    }

    func test输出告诉Agent改了什么并提醒它告诉用户() {
        let text = EditCommand.report(MetadataEditResponse(success: true, groupId: "baidu-qianfan",
            changes: [.groupRenamed(from: "百度千帆", to: "baidu-qianfan"), .fieldRenamed(from: "cc", to: "api-key")]))
        XCTAssertTrue(text.contains("百度千帆 → baidu-qianfan"))
        XCTAssertTrue(text.contains("cc → api-key"))
        XCTAssertTrue(text.contains("Tell the user"))
    }

    func test文件映射认旧组ID和旧字段名() throws {
        let meta = MetaFile(credentials: ["ga4": Credential(
            label: "GA4", notes: "", links: [],
            fields: ["credentials-json": .init(secret: true, fileFormat: .serviceAccountJSON, aliases: ["json"])],
            security: .strict, created: "", updated: "", aliases: ["ga4-service"])])
        let plan = try FileInjectionPlan(credentials: ["ga4"], mappings: ["ga4-service:json=GOOGLE_APPLICATION_CREDENTIALS"],
                                         prefix: "", meta: meta)
        XCTAssertEqual(plan.environmentName(credential: "ga4", field: "credentials-json"), "GOOGLE_APPLICATION_CREDENTIALS")
    }

    func test改名后run同时注入新旧环境变量() {
        let credential = Credential(label: "Q", notes: "", links: [],
                                    fields: ["api-key": .init(secret: true, aliases: ["cc", "API Key"])],
                                    security: .standard, created: "", updated: "")
        XCTAssertEqual(credential.environmentNames(forField: "api-key"), ["API_KEY", "CC"])
        XCTAssertEqual(credential.environmentNames(forField: "api-key", prefix: "Q_"), ["Q_API_KEY", "Q_CC"])
        XCTAssertEqual(try RunCommand.resolveCredentialIds(["百度千帆", "openai"], in: MetaFile(credentials: [
            "baidu-qianfan": Credential(label: "", notes: "", links: [], fields: [:], security: .standard,
                                        created: "", updated: "", aliases: ["百度千帆"]),
            "openai": Credential(label: "", notes: "", links: [], fields: [:], security: .standard, created: "", updated: ""),
        ])), ["baidu-qianfan", "openai"])
    }
}
