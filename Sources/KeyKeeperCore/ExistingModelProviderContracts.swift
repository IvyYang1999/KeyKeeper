import Foundation

/// Adds audited routing facts without renaming previously stored credentials or fields.
enum ExistingModelProviderContracts {
    private static let bailianSources = [
        "https://help.aliyun.com/zh/model-studio/get-api-key",
        "https://help.aliyun.com/zh/model-studio/base-url",
    ]
    private static let regions: [(id: String, name: String, region: String, host: String)] = [
        ("alibaba-bailian-sg", "新加坡", "ap-southeast-1", "dashscope-intl.aliyuncs.com"),
        ("alibaba-bailian-us", "美国弗吉尼亚", "us-east-1", "dashscope-us.aliyuncs.com"),
        ("alibaba-bailian-hk", "中国香港", "cn-hongkong", "cn-hongkong.dashscope.aliyuncs.com"),
    ]
    static let regionalTemplates: [ProviderTemplate] = regions.map { item in
        ModelProviderTemplate.make(id: item.id, name: "阿里云百炼 · 按量 (\(item.name))",
            env: "DASHSCOPE_API_KEY", createURL: "https://bailian.console.aliyun.com/",
            endpoints: bailianEndpoints(host: item.host, region: item.region),
            gates: ["登录阿里云，选择 \(item.name)（\(item.region)）与对应业务空间", "在 API Key 管理中创建该地区的按量 key；不要复制 Coding / Token Plan key", "配置同地区 endpoint；业务空间专属域名需从控制台确认 WorkspaceId"],
            permission: "不同地区的 key 不通用。优先独立业务空间、限制模型与 IP 的自定义权限。",
            sources: bailianSources, expiry: "本模板管理持久 API Key，无固定有效期；不是最多 1800 秒的临时 key。仍可能被撤销。")
    }

    private static func bailianEndpoints(host: String, region: String) -> [ProviderEndpoint] {
        [.init("OpenAI", "https://\(host)/compatible-mode/v1", region: region),
         .init("Anthropic", "https://\(host)/apps/anthropic", region: region),
         .init("DashScope", "https://\(host)/api/v1", region: region),
         .init("OpenAI · workspace (replace WorkspaceId)", "https://{WorkspaceId}.\(region).maas.aliyuncs.com/compatible-mode/v1", region: region)]
    }

    static func enrich(_ original: ProviderTemplate) -> ProviderTemplate {
        var t = original
        switch t.id {
        case "siliconflow", "siliconflow-global":
            t.endpoints = [.init("OpenAI", t.id == "siliconflow" ? "https://api.siliconflow.cn/v1" : "https://api.siliconflow.com/v1")]
            t.sources = ["https://docs.siliconflow.com/en/usercases/use-siliconcloud-in-DB-GPT"]
        case "deepseek":
            t.endpoints = [.init("OpenAI", "https://api.deepseek.com"), .init("Anthropic", "https://api.deepseek.com/anthropic")]
            t.sources = ["https://api-docs.deepseek.com/"]
        case "openrouter":
            t.endpoints = [.init("OpenAI", "https://openrouter.ai/api/v1")]
            t.sources = ["https://openrouter.ai/docs/cookbook/get-started/migrate-to-openrouter"]
        case "xai":
            t.endpoints = [.init("OpenAI", "https://api.x.ai/v1")]
            t.sources = ["https://docs.x.ai/developers/quickstart"]
        case "minimax", "minimax-global", "minimax-token-plan-cn", "minimax-token-plan-global":
            let china = t.id == "minimax" || t.id.hasSuffix("-cn")
            let host = china ? "api.minimaxi.com" : "api.minimax.io"
            t.endpoints = [.init("OpenAI", "https://\(host)/v1"), .init("Anthropic", "https://\(host)/anthropic")]
            t.fields[0].aliases = ["anthropic-auth-token", "anthropic-api-key", "openai-api-key"]
            t.sources = ["https://platform.minimax.io/docs/api-reference/api-overview",
                         "https://platform.minimax.io/docs/token-plan/other-tools",
                         "https://platform.minimax.io/docs/token-plan/claude-code",
                         "https://platform.minimax.io/docs/api-reference/text-anthropic-api"]
            t.gates.append("使用本模板对应的地区与计费类型；相同 endpoint 不代表按量与订阅 key 可以混用。")
        case "zhipu-cn", "zhipu-cn-coding", "zai-global", "zai-global-coding":
            let china = t.id.hasPrefix("zhipu")
            let coding = t.id.hasSuffix("coding")
            let host = china ? "open.bigmodel.cn" : "api.z.ai"
            t.endpoints = [.init("OpenAI Chat Completions", "https://\(host)/api/\(coding ? "coding/" : "")paas/v4", region: china ? "China" : "Global")]
            if coding {
                t.endpoints?.append(.init("Anthropic Messages", "https://\(host)/api/anthropic", region: china ? "China" : "Global"))
                t.endpoints?.append(.init("OpenAI Responses", "https://\(host)/api/v1", region: china ? "China" : "Global"))
            }
            t.sources = china
                ? ["https://docs.bigmodel.cn/cn/guide/develop/python/introduction", "https://docs.bigmodel.cn/cn/coding-plan/extension/coding-tool-helper", "https://docs.bigmodel.cn/cn/coding-plan/quick-start"]
                : ["https://docs.z.ai/api-reference/introduction", "https://docs.z.ai/devpack/quick-start"]
            if t.id == "zhipu-cn" { t.createURL = "https://bigmodel.cn/usercenter/proj-mgmt/apikeys"; t.rotateURL = t.createURL }
            if coding {
                t.gates.append(china
                    ? "个人套餐入口为当前创建页；团队套餐使用 https://bigmodel.cn/coding-plan?z_plan=team 的团队 key。"
                    : "个人套餐使用当前 API key 页并确认订阅；团队套餐使用 https://z.ai/manage-apikey/coding-plan/team/my-plan。")
            }
        case "alibaba-bailian":
            t.endpoints = bailianEndpoints(host: "dashscope.aliyuncs.com", region: "cn-beijing")
            t.sources = bailianSources
            t.gates.append("此模板固定北京 cn-beijing；其他地区选择对应模板，不允许跨地区复用 key。")
        case "alibaba-bailian-coding-cn", "alibaba-bailian-token-cn":
            let isTokenPlan = t.id.contains("-token-")
            let host = isTokenPlan ? "token-plan.cn-beijing.maas.aliyuncs.com" : "coding.dashscope.aliyuncs.com"
            t.endpoints = [.init("OpenAI", "https://\(host)/\(isTokenPlan ? "compatible-mode/v1" : "v1")", region: "cn-beijing"),
                           .init("Anthropic", "https://\(host)/apps/anthropic", region: "cn-beijing")]
            t.sources = bailianSources
            t.gates.append("仅限套餐允许的交互式 AI coding 工具，不能用于后端服务。")
        default: break
        }
        return t
    }
}
