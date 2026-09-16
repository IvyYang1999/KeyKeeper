import Foundation

/// Audited third-party model gateways. These templates describe the gateway's own credential;
/// protocol compatibility never means that an upstream model-vendor key belongs here.
enum GatewayModelProviderCatalog {
    static let all: [ProviderTemplate] = [
        atlasCloud, atlasCloudCoding,
        compshareModelVerseCN, compshareModelVerseGlobal, compshareAgentPlan,
        ccsub, micuClaude, micuCodex, rightCodeCodex, cubence, crazyrouter,
        dmxapiCN, dmxapiGlobal, dmxapiSSVIP, aiHubMix, amux, cherryIN,
    ]

    private static let atlasCloud = ModelProviderTemplate.make(
        id: "atlascloud",
        name: "Atlas Cloud · API (Pay-as-you-go)",
        aliases: ["atlas-cloud"],
        env: "ATLASCLOUD_API_KEY",
        createURL: "https://www.atlascloud.ai/console/api-keys",
        endpoints: [
            .init("OpenAI compatible", "https://api.atlascloud.ai/v1"),
            .init("Images, video and uploads", "https://api.atlascloud.ai/api/v1"),
        ],
        gates: ["登录 Atlas Cloud", "进入 API Keys 并创建独立密钥", "复制后立即保存：完整值只显示一次", "确认账户余额和模型可用地区"],
        permission: "普通按量密钥；不要当作 Coding Plan 密钥。为每个项目创建独立密钥，便于单独撤销。",
        sources: ["https://www.atlascloud.ai/docs/en/api-keys"],
        shownOnce: true)

    private static let atlasCloudCoding = ModelProviderTemplate.make(
        id: "atlascloud-coding-plan",
        name: "Atlas Cloud · Coding Plan",
        aliases: ["atlascloud-coding", "atlas-cloud-coding"],
        env: "ATLASCLOUD_CODING_API_KEY",
        envAliases: ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://www.atlascloud.ai/console/api-keys",
        endpoints: [
            .init("OpenAI compatible", "https://api.atlascloud.ai/v1"),
            .init("Anthropic Messages", "https://api.atlascloud.ai"),
        ],
        gates: ["登录 Atlas Cloud", "购买或选择 Coding Plan", "在 Plan Management 中获取专用 API key", "确认套餐仍有效且配额未耗尽"],
        permission: "仅保存 Coding Plan 专用密钥；官方明确说明它与普通 Atlas Cloud API key 分离。仅用于套餐支持的 coding 工具。",
        sources: ["https://www.atlascloud.ai/docs/coding-plan/api"])

    private static let compshareModelVerseCN = ModelProviderTemplate.make(
        id: "compshare-modelverse-cn",
        name: "Compshare · ModelVerse (China)",
        aliases: ["modelverse", "compshare-cn"],
        env: "COMPSHARE_API_KEY",
        createURL: "https://console.compshare.cn/",
        endpoints: [
            .init("OpenAI compatible", "https://api.modelverse.cn/v1", region: "China"),
            .init("Anthropic Messages", "https://api.modelverse.cn", region: "China"),
            .init("Gemini compatible", "https://api.modelverse.cn", region: "China"),
        ],
        gates: ["登录 Compshare 控制台", "进入 ModelVerse API Key 管理", "创建项目专用密钥", "确认按量余额和目标模型可用"],
        permission: "普通 ModelVerse 按量密钥；不要当作 Agent Plan 密钥。按项目拆分密钥并设置可承受的使用边界。",
        sources: [
            "https://compshare.cn/docs/modelverse/models/quick-start",
            "https://compshare.cn/docs/modelverse/models/common/certificate",
        ])

    private static let compshareModelVerseGlobal = ModelProviderTemplate.make(
        id: "compshare-modelverse-global",
        name: "Compshare · ModelVerse (Global)",
        aliases: ["umodelverse", "compshare-global"],
        env: "COMPSHARE_API_KEY",
        createURL: "https://console.compshare.cn/",
        endpoints: [
            .init("OpenAI compatible", "https://api.umodelverse.ai/v1", region: "Global fallback"),
            .init("Anthropic Messages", "https://api.umodelverse.ai", region: "Global fallback"),
            .init("Gemini compatible", "https://api.umodelverse.ai", region: "Global fallback"),
        ],
        gates: ["登录 Compshare 控制台", "进入 ModelVerse API Key 管理", "创建项目专用密钥", "仅在 .cn 入口不可达时选择官方海外入口"],
        permission: "普通 ModelVerse 按量密钥；海外域名是官方备用访问地址，不是 Agent Plan。按项目拆分密钥。",
        sources: [
            "https://compshare.cn/docs/modelverse/models/quick-start",
            "https://compshare.cn/docs/modelverse/models/common/certificate",
        ])

    private static let compshareAgentPlan = ModelProviderTemplate.make(
        id: "compshare-agent-plan",
        name: "Compshare · Agent Plan",
        aliases: ["compshare-coding", "compshare-coding-plan"],
        env: "COMPSHARE_AGENT_PLAN_API_KEY",
        envAliases: ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://console.compshare.cn/light-gpu/model-manage",
        endpoints: [
            .init("OpenAI compatible", "https://cp.compshare.cn/v1"),
            .init("Anthropic Messages", "https://cp.compshare.cn"),
        ],
        gates: ["登录 Compshare", "购买 Agent Plan", "在模型管理页面创建套餐专用 API Key", "确认套餐未过期且配额未耗尽"],
        permission: "仅保存 Agent Plan 专用 key；官方明确要求从普通按量 API 切换时同时更换 Base URL 和 API Key。不要保存本地 ccx 代理的 PROXY_ACCESS_KEY。",
        sources: [
            "https://compshare.cn/docs/modelverse/codingfaq",
            "https://compshare.cn/docs/modelverse/package_plan/usecases",
            "https://compshare.cn/docs/modelverse/best_practice/codexagent",
        ],
        expiry: "密钥随 Agent Plan 到期或配额耗尽而停止工作；实际到期日以账户套餐页为准。")

    private static let ccsub = ModelProviderTemplate.make(
        id: "ccsub",
        name: "CCSub",
        env: "CCSUB_API_KEY",
        envAliases: ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://www.ccsub.net/keys",
        endpoints: [
            .init("OpenAI compatible", "https://www.ccsub.net/v1"),
            .init("Anthropic Messages", "https://www.ccsub.net"),
        ],
        gates: ["登录 CCSub", "进入 API Keys 页面", "创建独立密钥", "确认账户套餐或余额可用"],
        permission: "一个 CCSub key 可按官方配置用于 OpenAI 或 Anthropic 兼容客户端；为每个项目单独创建，避免跨工具复用。",
        sources: ["https://www.ccsub.net/docs/install"])

    private static let micuClaude = ModelProviderTemplate.make(
        id: "micu-claude",
        name: "Micu API · Claude Code",
        aliases: ["micu-anthropic"],
        env: "MICU_API_KEY",
        envAliases: ["ANTHROPIC_API_KEY"],
        createURL: "https://www.micuapi.ai/sign-in?redirect=%2Fdashboard",
        endpoints: [.init("Anthropic Messages", "https://www.micuapi.ai")],
        gates: ["登录 Micu 控制台", "在令牌管理创建 Token", "选择与 Claude 模型匹配的渠道分组", "确认 Token 未过期且余额充足"],
        permission: "仅保存为 Claude/Anthropic 协议和对应渠道分组创建的 Micu Token；分组不匹配会被拒绝，不要假设它与 Codex 分组互通。",
        sources: [
            "https://docs.micuapi.ai/claude-code/config",
            "https://docs.micuapi.ai/external-compat",
        ])

    private static let micuCodex = ModelProviderTemplate.make(
        id: "micu-codex",
        name: "Micu API · Codex",
        aliases: ["micu-openai"],
        env: "MICU_API_KEY",
        envAliases: ["OPENAI_API_KEY"],
        createURL: "https://www.micuapi.ai/sign-in?redirect=%2Fdashboard",
        endpoints: [.init("OpenAI Responses", "https://www.micuapi.ai/v1")],
        gates: ["登录 Micu 控制台", "在令牌管理创建 Token", "选择与 Codex 模型匹配的渠道分组", "确认 Token 未过期且余额充足"],
        permission: "仅保存为 Codex/OpenAI Responses 协议和对应渠道分组创建的 Micu Token；不要假设它与 Claude 分组互通。",
        sources: ["https://docs.micuapi.ai/external-compat"])

    private static let rightCodeCodex = ModelProviderTemplate.make(
        id: "rightcode-codex",
        name: "RightCode · Codex",
        aliases: ["right-code", "rightcode"],
        env: "RIGHTCODE_API_KEY",
        envAliases: ["OPENAI_API_KEY"],
        createURL: "https://rightapi.ai/",
        endpoints: [.init("OpenAI Responses", "https://rightapi.ai/codex/v1")],
        gates: ["登录 RightCode 后台", "进入令牌管理并创建密钥", "确认密钥允许所需模型", "若只用 Codex 套餐，关闭“允许使用余额”以防额外按量扣费"],
        permission: "仅开放任务需要的模型；是否允许套餐耗尽后继续扣余额必须由用户明确选择。此模板只覆盖官方文档确认的 Codex endpoint。",
        sources: [
            "https://docs.right.codes/docs/rc_quick_start/apikey",
            "https://docs.right.codes/docs/rc_cli_config/codex",
        ])

    private static let cubence = ModelProviderTemplate.make(
        id: "cubence",
        name: "Cubence",
        env: "CUBENCE_API_KEY",
        envAliases: ["OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://cubence.com/dashboard/keys",
        endpoints: [
            .init("OpenAI compatible", "https://api.cubence.com/v1"),
            .init("Anthropic Messages", "https://api.cubence.com"),
        ],
        gates: ["登录 Cubence", "进入 Key Management 并创建 key", "设置项目可承受的 Quota Limit", "确认服务地区和模型当前可用"],
        permission: "按应用或环境创建独立 key，并设置固定额度；官方当前说明为按量计费，不提供订阅套餐。",
        sources: [
            "https://docs.cubence.com/en/docs/quick-start",
            "https://docs.cubence.com/en/docs/guides/endpoints",
            "https://docs.cubence.com/en/docs/setup/claude-code",
            "https://docs.cubence.com/en/docs/setup/codex",
        ])

    private static let crazyrouter = ModelProviderTemplate.make(
        id: "crazyrouter",
        name: "CrazyRouter",
        env: "CRAZYROUTER_API_KEY",
        envAliases: ["OPENAI_API_KEY"],
        createURL: "https://crazyrouter.com/",
        endpoints: [
            .init("OpenAI compatible", "https://api.crazyrouter.com/v1", region: "International"),
            .init("Anthropic Messages", "https://api.crazyrouter.com", region: "International"),
            .init("OpenAI compatible", "https://cn.crazyrouter.com/v1", region: "East Asia"),
            .init("Anthropic Messages", "https://cn.crazyrouter.com", region: "East Asia"),
        ],
        gates: ["登录 CrazyRouter 控制台", "进入 Token Management 创建专用 token", "限制可用模型", "设置 IP 限制和额度上限（适用时）"],
        permission: "为每个 IDE、CLI 或 bot 创建不同 token；限制模型、IP 和日/月预算。模型 API 必须发往 API 域名，账户管理仍使用 crazyrouter.com。",
        sources: [
            "https://docs.crazyrouter.com/en/openclaw-deploy",
            "https://docs.crazyrouter.com/en/api-endpoint",
        ],
        prefixes: ["sk-"])

    private static let dmxapiCN = dmx(
        id: "dmxapi-cn", name: "DMXAPI · 国内站", createURL: "https://www.dmxapi.cn",
        root: "https://www.dmxapi.cn", region: "China · CNY discounted")

    private static let dmxapiGlobal = dmx(
        id: "dmxapi-global", name: "DMXAPI · 国际站", createURL: "https://www.dmxapi.com",
        root: "https://www.dmxapi.com", region: "Global · USD discounted")

    private static let dmxapiSSVIP = dmx(
        id: "dmxapi-ssvip", name: "DMXAPI · SSVIP 国际服", createURL: "https://ssvip.dmxapi.com",
        root: "https://ssvip.dmxapi.com", region: "Global · USD undiscounted")

    private static func dmx(id: String, name: String, createURL: String,
                            root: String, region: String) -> ProviderTemplate {
        ModelProviderTemplate.make(
            id: id,
            name: name,
            env: "DMX_API_KEY",
            createURL: createURL,
            endpoints: [
                .init("OpenAI compatible", "\(root)/v1", region: region),
                .init("Anthropic Messages", root, region: region),
            ],
            gates: ["登录这一 DMXAPI 站点", "进入工作台 → 令牌管理", "添加令牌并保持 default 分组", "按需设置过期、模型、IP 和速率限制"],
            permission: "令牌与站点域名必须配套，禁止跨国内站、国际站和 SSVIP 混用。限制到任务需要的模型、IP、速率和有效期。",
            sources: [
                "https://doc.dmxapi.com/lingpai.html",
                "https://doc.dmxapi.com/baseurl.html",
            ],
            expiry: "创建时可设置到期时间；官方默认永久有效。以该令牌在创建页面选择的实际设置为准。")
    }

    private static let aiHubMix = ModelProviderTemplate.make(
        id: "aihubmix",
        name: "AIHubMix",
        aliases: ["ai-hub-mix"],
        env: "AIHUBMIX_API_KEY",
        createURL: "https://aihubmix.com/token",
        endpoints: [
            .init("OpenAI compatible", "https://aihubmix.com/v1", region: "Primary"),
            .init("OpenAI compatible", "https://api.inferera.com/v1", region: "Official backup"),
        ],
        gates: ["登录 AIHubMix", "创建独立 API key", "记录该 key 页面显示的有效期", "确认使用限制和余额"],
        permission: "为每个项目创建独立 key，并按创建页面的有效期和使用限制收窄风险。备用域名只在主域名访问异常时使用。",
        sources: ["https://docs.aihubmix.com/en/quick-start"],
        expiry: "官方要求留意每个 key 的 validity period；具体日期以创建页面显示为准。")

    private static let amux = ModelProviderTemplate.make(
        id: "amux",
        name: "Amux API",
        env: "AMUX_API_KEY",
        createURL: "https://amux.ai/keys",
        endpoints: [
            .init("OpenAI compatible", "https://gateway.amux.ai/v1"),
            .init("Anthropic Messages", "https://gateway.amux.ai"),
            .init("Gemini native", "https://gateway.amux.ai"),
        ],
        gates: ["登录 Amux", "先选择个人或组织 workspace 作为计费主体", "充值后在 API keys 页面创建项目专用 key", "确认该 workspace 的余额"],
        permission: "key 属于 workspace，费用由该 workspace 所属账户承担；按项目拆分 key。当前官方说明为预付按量计费，尚无订阅。",
        sources: [
            "https://amux.ai/docs/quickstart",
            "https://amux.ai/api-reference",
        ],
        expiry: "官方未说明统一到期策略；完整 key 可在 keys 页面再次查看，不需要仅为找回值而轮换。")

    private static let cherryIN = ModelProviderTemplate.make(
        id: "cherryin",
        name: "CherryIN",
        aliases: ["cherry-in"],
        env: "CHERRYIN_API_KEY",
        envAliases: ["ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://open.cherryin.net",
        endpoints: [
            .init("OpenAI compatible", "https://open.cherryin.net/v1"),
            .init("Anthropic Messages", "https://open.cherryin.net"),
        ],
        gates: ["登录 CherryIN Console", "充值后进入 Token Management", "添加 Token 并选择分组", "默认组用于通用模型；促销组 token 必须与对应模型组匹配"],
        permission: "日常通用调用使用 default 组的独立 token；折扣/促销组另建 token，禁止把组别不同的 key 当作可互换。为 key 设置用户可承受的额度。",
        sources: [
            "https://docs.cherryin.ai/en/docs/newapi/getting-started/",
            "https://docs.cherryin.ai/en/docs/newapi/openai-compatible-usage/",
            "https://docs.cherryin.ai/en/docs/newapi/claude-code-usage/",
        ])
}
