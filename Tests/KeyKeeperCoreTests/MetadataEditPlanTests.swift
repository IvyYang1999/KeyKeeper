import XCTest
@testable import KeyKeeperCore

/// yyt 2026-09-11：标题、备注、字段显示名只是给人和 Agent 看的备注，谁都能随手改；
/// 组 ID 和字段名也能改，但旧名字要一直能用；改了告诉用户一声，不弹窗。
final class MetadataEditPlanTests: XCTestCase {
    private func meta() -> MetaFile {
        MetaFile(credentials: [
            "百度千帆": Credential(label: "百度千帆", notes: "学术搜索", links: [],
                               fields: ["cc": CredentialField(secret: true)], security: .standard,
                               created: "2026-03-02", updated: "2026-03-02"),
            "openai": Credential(label: "OpenAI", notes: "", links: [],
                                 fields: ["api-key": CredentialField(secret: true)], security: .strict,
                                 created: "2026-09-01", updated: "2026-09-01"),
        ])
    }

    func test人随手起的名字转成机器名() {
        XCTAssertEqual(CredentialNames.slug("百度千帆"), "bai-du-qian-fan")
        XCTAssertEqual(CredentialNames.slug("  API Key "), "api-key")
        XCTAssertEqual(CredentialNames.slug("Stripe Live (prod)"), "stripe-live-prod")
        XCTAssertEqual(CredentialNames.slug("Crème Brûlée_2"), "creme-brulee_2")
        XCTAssertEqual(CredentialNames.slug("🔑🔑"), "")
        XCTAssertTrue(CredentialNames.isValidGroupId("baidu-qianfan"))
        XCTAssertFalse(CredentialNames.isValidGroupId("百度千帆"))
        XCTAssertFalse(CredentialNames.isValidGroupId("Upper"))
        XCTAssertFalse(CredentialNames.isValidGroupId("-lead"))
        XCTAssertTrue(CredentialNames.isValidFieldName("API_KEY"))
        XCTAssertFalse(CredentialNames.isValidFieldName("api key"))
        XCTAssertFalse(CredentialNames.isValidFieldName("a:b"), "--file id:field=ENV 用冒号和等号分隔")
    }

    func test改组ID和字段名后旧名一直能找到() throws {
        let result = try MetadataEditPlan.apply(
            MetadataEdit(newGroupId: "baidu-qianfan", fieldRenames: ["cc": "api-key"]),
            to: meta(), groupId: "百度千帆")
        XCTAssertEqual(result.groupId, "baidu-qianfan")
        XCTAssertNil(result.meta.credentials["百度千帆"])
        let credential = try XCTUnwrap(result.meta.credentials["baidu-qianfan"])
        XCTAssertEqual(credential.aliases, ["百度千帆"])
        XCTAssertEqual(credential.fields["api-key"]?.aliases, ["cc"])
        XCTAssertNil(credential.fields["cc"])
        XCTAssertEqual(credential.label, "百度千帆", "标题不跟着变")
        XCTAssertEqual(result.fieldMap, ["cc": "api-key"])
        XCTAssertEqual(result.changes, [.groupRenamed(from: "百度千帆", to: "baidu-qianfan"),
                                        .fieldRenamed(from: "cc", to: "api-key")])

        XCTAssertEqual(result.meta.resolveGroupId("百度千帆"), "baidu-qianfan")
        XCTAssertEqual(result.meta.resolveGroupId("baidu-qianfan"), "baidu-qianfan")
        XCTAssertNil(result.meta.resolveGroupId("nope"))
        XCTAssertEqual(credential.resolveFieldName("cc"), "api-key")
        XCTAssertEqual(credential.resolveFieldName("api-key"), "api-key")

        // 再改一次，两代旧名都保留；改回旧名时它从旧名单里拿掉。
        let again = try MetadataEditPlan.apply(MetadataEdit(newGroupId: "qianfan"), to: result.meta, groupId: "百度千帆")
        XCTAssertEqual(again.meta.credentials["qianfan"]?.aliases, ["百度千帆", "baidu-qianfan"])
        let back = try MetadataEditPlan.apply(MetadataEdit(newGroupId: "baidu-qianfan"), to: again.meta, groupId: "qianfan")
        XCTAssertEqual(back.meta.credentials["baidu-qianfan"]?.aliases, ["百度千帆", "qianfan"])
    }

    func test新名字不能撞上别人的现名或旧名() throws {
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(newGroupId: "openai"), to: meta(), groupId: "百度千帆")) {
            XCTAssertEqual($0 as? MetadataEditError, .groupIdTaken("openai"))
        }
        let renamed = try MetadataEditPlan.apply(MetadataEdit(newGroupId: "qianfan"), to: meta(), groupId: "百度千帆").meta
        // 旧名一直保留，所以别人也不能再占用「百度千帆」。
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(newGroupId: "百度千帆"), to: renamed, groupId: "openai"))
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(newGroupId: "Bad Name"), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .invalidGroupId("Bad Name"))
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(fieldRenames: ["missing": "x"]), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .fieldNotFound("missing"))
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(), to: meta(), groupId: "nope")) {
            XCTAssertEqual($0 as? MetadataEditError, .notFound("nope"))
        }
    }

    func test标题备注显示名随便改但安全级别和值不在这里() throws {
        let result = try MetadataEditPlan.apply(
            MetadataEdit(title: "百度千帆 · 学术", notes: "论文检索用", fieldDisplayNames: ["cc": "API Key "]),
            to: meta(), groupId: "百度千帆")
        let credential = try XCTUnwrap(result.meta.credentials["百度千帆"])
        XCTAssertEqual(credential.label, "百度千帆 · 学术")
        XCTAssertEqual(credential.notes, "论文检索用")
        XCTAssertEqual(credential.fields["cc"]?.displayName, "API Key")
        XCTAssertEqual(credential.security, .standard)
        XCTAssertEqual(result.changes.count, 3)

        let cleared = try MetadataEditPlan.apply(MetadataEdit(fieldDisplayNames: ["cc": " "]), to: result.meta, groupId: "百度千帆")
        XCTAssertNil(cleared.meta.credentials["百度千帆"]?.fields["cc"]?.displayName)
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .nothingToChange)
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(notes: String(repeating: "x", count: 4001)), to: meta(), groupId: "openai"))
    }

    func test旧版meta没有新字段也能读写不变() throws {
        let old = #"{"credentials":{"a":{"created":"x","fields":{"k":{"secret":true}},"label":"A","links":[],"notes":"","security":"standard","updated":"x"}},"version":1}"#
        let decoded = try JSONDecoder().decode(MetaFile.self, from: Data(old.utf8))
        XCTAssertNil(decoded.credentials["a"]?.aliases)
        XCTAssertNil(decoded.credentials["a"]?.fields["k"]?.displayName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(decoded), encoding: .utf8), old)
    }
}
