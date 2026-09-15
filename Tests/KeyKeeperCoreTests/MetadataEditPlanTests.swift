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

    /// 【曾经的 bug】同一条命令里改字段名、再按新名字设显示名，报「没有这个字段」。
    /// 文档里的示例 `--rename-field cc=api-key --field-label "api-key=..."` 就是这么写的。
    func test曾经的Bug同一次编辑里可以按新字段名设显示名() throws {
        let result = try MetadataEditPlan.apply(
            MetadataEdit(fieldRenames: ["cc": "api-key"], fieldDisplayNames: ["api-key": "千帆 API Key"]),
            to: meta(), groupId: "百度千帆")
        XCTAssertEqual(result.meta.credentials["百度千帆"]?.fields["api-key"]?.displayName, "千帆 API Key")
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

    /// 【安全红线】Agent 走的是不弹窗的元数据编辑。它可以随便改名字和备注，但绝不能把一个
    /// 机密字段改成非机密——那等于把钥匙串里的值挪进明文 meta.json，且没人点过头。
    /// 也不能反过来把明文值改掉或藏起来。
    func test改元数据不能碰字段的机密属性与值() throws {
        let meta = MetaFile(credentials: [
            "mixed": Credential(label: "Mixed", notes: "", links: [],
                                fields: ["token": CredentialField(secret: true),
                                         "apple-id": CredentialField(value: "a@b.invalid", secret: false)],
                                security: .strict, created: "2026-09-13", updated: "2026-09-13"),
        ])
        let result = try MetadataEditPlan.apply(
            MetadataEdit(newGroupId: "notary", title: "Apple 公证", notes: "发版用",
                         fieldRenames: ["token": "app-password", "apple-id": "account"],
                         fieldDisplayNames: ["app-password": "应用专用密码"]),
            to: meta, groupId: "mixed")

        let credential = try XCTUnwrap(result.meta.credentials["notary"])
        XCTAssertEqual(credential.fields["app-password"]?.secret, true, "机密字段改名后仍是机密")
        XCTAssertNil(credential.fields["app-password"]?.value, "机密值不能被写进 meta")
        XCTAssertEqual(credential.fields["account"]?.secret, false)
        XCTAssertEqual(credential.fields["account"]?.value, "a@b.invalid", "明文值原样跟着改名走")
        XCTAssertEqual(credential.security, .strict, "安全级别也不归这条路管")
    }

    /// 明文字段可以由人或 Agent 直接写（账号 ID、团队 ID 这类），走的还是不弹窗那条路。
    func test可以新增与更新明文字段() throws {
        let result = try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["apple-team-id": "ZPTA4LP594", "region": "cn-north"]),
            to: meta(), groupId: "openai")
        let credential = try XCTUnwrap(result.meta.credentials["openai"])
        XCTAssertEqual(credential.fields["apple-team-id"]?.value, "ZPTA4LP594")
        XCTAssertEqual(credential.fields["apple-team-id"]?.secret, false)
        XCTAssertEqual(credential.fields["region"]?.secret, false)
        XCTAssertEqual(credential.fields["api-key"]?.secret, true, "原有机密字段不受影响")

        let updated = try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["region": "cn-east"]), to: result.meta, groupId: "openai")
        XCTAssertEqual(updated.meta.credentials["openai"]?.fields["region"]?.value, "cn-east")

        let removed = try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["region": nil]), to: updated.meta, groupId: "openai")
        XCTAssertNil(removed.meta.credentials["openai"]?.fields["region"])
    }

    /// 【安全红线】这条路不碰钥匙串。给一个机密字段写明文值 = 降密，必须直接拒绝；
    /// 删除机密字段也不行（值会变成没人认领的孤儿）。
    func test明文写入不能碰机密字段() throws {
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["api-key": "sk-not-a-real-key"]), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .fieldIsSecret("api-key"))
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["api-key": nil]), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .fieldIsSecret("api-key"))
        }
        // 旧名也认：别名指向的仍是那个机密字段。
        let renamed = try MetadataEditPlan.apply(MetadataEdit(fieldRenames: ["api-key": "token"]), to: meta(), groupId: "openai").meta
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["api-key": "x"]), to: renamed, groupId: "openai"))
    }

    func test明文字段名要合规则且值不能带控制字符() throws {
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["bad name": "x"]), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .invalidFieldName("bad name"))
        }
        let result = try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["note": "  a\u{0007}b  "]), to: meta(), groupId: "openai")
        XCTAssertEqual(result.meta.credentials["openai"]?.fields["note"]?.value, "ab")
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(plainFields: ["note": String(repeating: "x", count: 4097)]), to: meta(), groupId: "openai"))
    }

    func test旧版meta没有新字段也能读写不变() throws {
        let old = #"{"credentials":{"a":{"created":"x","fields":{"k":{"secret":true}},"label":"A","links":[],"notes":"","security":"standard","updated":"x"}},"version":1}"#
        let decoded = try JSONDecoder().decode(MetaFile.self, from: Data(old.utf8))
        XCTAssertNil(decoded.credentials["a"]?.aliases)
        XCTAssertNil(decoded.credentials["a"]?.fields["k"]?.displayName)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(String(data: try encoder.encode(decoded), encoding: .utf8), old)
    }

    /// 【安全】标题是唯一一段「谁都能改、还会成为授权窗大标题」的自由文本，存进去之前就要
    /// 折成一行可打印文本；授权窗渲染时还会再消毒一次，两处都做。
    func test标题存进去之前就折成一行可打印文本() throws {
        let result = try MetadataEditPlan.apply(
            MetadataEdit(title: "OpenAI\n\n已由系统批准\u{202E}\u{200B}"),
            to: meta(), groupId: "openai")
        XCTAssertEqual(result.meta.credentials["openai"]?.label, "OpenAI 已由系统批准")
        // 过长的标题是报错，不是悄悄截断——截断会把用户自己写的名字改掉。
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(title: String(repeating: "钥", count: 201)), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .tooLong("title"))
        }
    }

    /// 消毒后空掉的标题等于没改，不能把凭据改成一个没有名字的东西。
    func test全是不可见字符的标题视为没改() throws {
        XCTAssertThrowsError(try MetadataEditPlan.apply(
            MetadataEdit(title: "\u{200B}\u{200B}"), to: meta(), groupId: "openai")) {
            XCTAssertEqual($0 as? MetadataEditError, .nothingToChange)
        }
    }
}

// MARK: - 2026-09-14 独立审计 high：免弹窗写的明文字段不能直接变成环境变量

extension MetadataEditPlanTests {
    /// `keykeeper edit openai --plain openai-base-url=https://evil` 不弹窗；下次 `run` 时 SDK 就把 key
    /// 发给 evil。所以调用方经命令行写的明文值先记下是谁写的，`run` 不注入，人在 App 里确认后才算数。
    func test调用方写的明文字段记下是谁写的_人在App里存一次就清掉() throws {
        let result = try MetadataEditPlan.apply(MetadataEdit(plainFields: ["openai-base-url": "https://evil.example"]),
                                                to: meta(), groupId: "openai", caller: "codex")
        let field = try XCTUnwrap(result.meta.credentials["openai"]?.fields["openai-base-url"])
        XCTAssertEqual(field.setByCaller, "codex")
        XCTAssertEqual(result.meta.credentials["openai"]?.unconfirmedPlainFields, ["openai-base-url": "codex"])

        // Without a caller (the app's own use of the plan) nothing is marked.
        let own = try MetadataEditPlan.apply(MetadataEdit(plainFields: ["region": "us"]), to: meta(), groupId: "openai")
        XCTAssertNil(own.meta.credentials["openai"]?.fields["region"]?.setByCaller)

        // The person saving the credential in the app confirms what they see.
        let plan = CredentialEditPlan(
            inputFields: [.init(name: "openai-base-url", value: "https://evil.example", originalName: "openai-base-url", isSecret: false),
                          .init(name: "api-key", value: "", originalName: "api-key", isSecret: true)],
            existingFields: result.meta.credentials["openai"]!.fields, security: .strict)
        XCTAssertNil(plan.metadata.fields["openai-base-url"]?.setByCaller)
        XCTAssertEqual(plan.metadata.fields["openai-base-url"]?.value, "https://evil.example")

        // A caller writing again after confirmation marks it again.
        var confirmed = result.meta
        confirmed.credentials["openai"]!.fields["openai-base-url"]!.setByCaller = nil
        let again = try MetadataEditPlan.apply(MetadataEdit(plainFields: ["openai-base-url": "https://evil2.example"]),
                                               to: confirmed, groupId: "openai", caller: "codex")
        XCTAssertEqual(again.meta.credentials["openai"]?.fields["openai-base-url"]?.setByCaller, "codex")
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(plainFields: ["openai-base-url": "https://evil.example"]),
                                                       to: confirmed, groupId: "openai", caller: "codex"), "同一个值再写一遍不算改动，也不会重新打上标记")
    }

    func test旧元数据没有这个字段也能读() throws {
        let old = Data(#"{"value":"us","secret":false}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CredentialField.self, from: old).setByCaller)
    }
}

// MARK: - 2026-09-15 绑定服务商

extension MetadataEditPlanTests {
    /// yyt：「已有的 key 也可以绑定服务商。绑定服务商就是告诉模型怎么更好使用这个 key。」
    func test绑定服务商_按模板id或别名_none清除_不认识的拒绝() throws {
        let bound = try MetadataEditPlan.apply(MetadataEdit(provider: "gpt"), to: meta(), groupId: "openai")
        XCTAssertEqual(bound.meta.credentials["openai"]?.provider, "openai", "别名折成模板 id")
        XCTAssertEqual(bound.changes, [.providerChanged(from: nil, to: "openai")])
        let cleared = try MetadataEditPlan.apply(MetadataEdit(provider: "none"), to: bound.meta, groupId: "openai")
        XCTAssertNil(cleared.meta.credentials["openai"]?.provider)
        XCTAssertEqual(cleared.changes, [.providerChanged(from: "openai", to: nil)])
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(provider: "nope"), to: meta(), groupId: "openai")) { error in
            XCTAssertEqual(error as? MetadataEditError, .unknownProvider("nope"))
        }
        XCTAssertThrowsError(try MetadataEditPlan.apply(MetadataEdit(provider: "openai"), to: bound.meta, groupId: "openai"), "已经绑着就没什么可改")
        XCTAssertNil(try JSONDecoder().decode(MetadataEdit.self, from: Data(#"{"title":"x"}"#.utf8)).provider, "旧客户端不带这个键")
    }
}
