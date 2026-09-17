import Foundation

/// Audited routing gateways whose credential identity is distinct from the upstream model vendors.
enum RoutingModelProviderCatalog {
    static let all: [ProviderTemplate] = [
        openCodeConsole, openCodeGo, pipeLLM, relaxyCode, theRouter, zenMuxPayg, zenMuxBuilder,
    ]

    private static let zenMuxPayg = ModelProviderTemplate.make(
        id: "zenmux-payg", name: "ZenMux · Pay As You Go", aliases: ["zenmux"],
        env: "ZENMUX_API_KEY", createURL: "https://zenmux.ai/platform/pay-as-you-go",
        endpoints: [
            .init("OpenAI compatible", "https://zenmux.ai/api/v1"),
            .init("Anthropic Messages", "https://zenmux.ai/api/anthropic"),
            .init("Google Vertex AI compatible", "https://zenmux.ai/api/vertex-ai"),
        ],
        gates: ["登录 ZenMux", "选择 Pay As You Go 管理页而非订阅页", "为独立项目创建按量 API key", "核对账户余额和目标模型可用性"],
        permission: "Only save a pay-as-you-go API key from this page. A Builder Plan subscription key uses a different billing balance; use zenmux-builder instead. No general key-scope guarantee is documented.",
        sources: ["https://zenmux.ai/docs/guide/quickstart", "https://zenmux.ai/docs/guide/subscription"],
        verified: "2026-09-17")

    private static let zenMuxBuilder = ModelProviderTemplate.make(
        id: "zenmux-builder", name: "ZenMux · Builder Plan", aliases: ["zenmux-subscription"],
        env: "ZENMUX_API_KEY", createURL: "https://zenmux.ai/platform/subscription",
        endpoints: [
            .init("OpenAI compatible", "https://zenmux.ai/api/v1"),
            .init("Anthropic Messages", "https://zenmux.ai/api/anthropic"),
            .init("Google Vertex AI compatible", "https://zenmux.ai/api/vertex-ai"),
        ],
        gates: ["登录 ZenMux", "选择 Builder Plan 并确认套餐规则", "购买后在订阅管理页创建订阅专属 API key", "确认套餐有效且目标模型在套餐范围内"],
        permission: "Only save a subscription-specific Builder Plan API key here. It consumes the plan's quota rather than pay-as-you-go balance; do not reuse a pay-as-you-go key.",
        sources: ["https://zenmux.ai/docs/guide/subscription", "https://zenmux.ai/docs/guide/quickstart"],
        verified: "2026-09-17")

    private static let openCodeConsole = ModelProviderTemplate.make(
        id: "opencode-zen",
        name: "OpenCode · Zen (Console)",
        aliases: ["opencode-console"],
        env: "OPENCODE_API_KEY",
        createURL: "https://opencode.ai/console/",
        endpoints: [
            .init("OpenAI Responses / Chat Completions", "https://opencode.ai/zen/v1"),
            .init("Anthropic Messages", "https://opencode.ai/zen/v1"),
            .init("Gemini", "https://opencode.ai/zen/v1"),
        ],
        gates: ["登录 OpenCode Console", "添加按量余额", "复制 Console API key"],
        permission: "按量 Console 与 Go 是不同计费产品；官方未确认两者的 key 可互换，保存和路由时不要混用。Console 未公开按 key 权限范围，按项目单独创建便于撤销。",
        sources: [
            "https://opencode.ai/v2/docs/console/models/",
            "https://opencode.ai/v2/docs/providers",
            "https://github.com/anomalyco/opencode/blob/dev/.github/workflows/opencode.yml",
        ])

    private static let openCodeGo = ModelProviderTemplate.make(
        id: "opencode-go",
        name: "OpenCode · Go",
        env: "OPENCODE_API_KEY",
        createURL: "https://opencode.ai/console/",
        endpoints: [
            .init("OpenAI Responses / Chat Completions", "https://opencode.ai/zen/go/v1"),
            .init("Anthropic Messages", "https://opencode.ai/zen/go/v1"),
        ],
        gates: ["登录 OpenCode Console", "订阅 Go 并添加账单信息", "复制 Go API key"],
        permission: "Go 是订阅套餐，Console 是按量产品；官方未确认两者的 key 可互换，因此必须按不可互换处理并分别保存。Go 未公开按 key 权限范围。",
        sources: [
            "https://opencode.ai/v2/docs/console/go",
            "https://opencode.ai/v2/docs/providers",
            "https://github.com/anomalyco/opencode/blob/dev/.github/workflows/opencode.yml",
        ])

    private static let pipeLLM = ModelProviderTemplate.make(
        id: "pipellm",
        name: "PipeLLM",
        env: "PIPELLM_API_KEY",
        createURL: "https://console.pipellm.ai/",
        endpoints: [
            .init("Native public routes", "https://api.pipellm.ai"),
            .init("OpenAI converter", "https://api.pipellm.ai/openai/v1"),
            .init("Anthropic converter", "https://api.pipellm.ai/anthropic"),
            .init("Gemini converter", "https://api.pipellm.ai/gemini"),
        ],
        gates: ["注册并登录 PipeLLM Console", "充值余额", "创建 API key"],
        permission: "官方文档未说明可为 key 设置细粒度权限；为每个项目创建独立 key，并只把固定的 PipeLLM base URL 配给调用方。",
        sources: [
            "https://docs.pipellm.ai/quickstart",
            "https://docs.pipellm.ai/api-reference/introduction",
            "https://docs.pipellm.ai/api-reference/list-models",
        ])

    private static let relaxyCode = ModelProviderTemplate.make(
        id: "relaxycode",
        name: "RelaxyCode",
        aliases: ["relaxy-code"],
        env: "OPENAI_API_KEY",
        createURL: "https://www.relaxycode.com/dashboard/api-keys",
        endpoints: [
            .init("OpenAI Responses for Codex", "https://api.relaxycode.com/v1"),
        ],
        gates: ["注册并登录 RelaxyCode", "充值或购买套餐", "在控制台创建并绑定套餐或余额的 API key"],
        permission: "按官方首页在创建时绑定所需套餐或余额。Codex 教程中的“DMXAPI token”与 RelaxyCode 域名不一致，不能据此接受其他发行方 token；仅保存 RelaxyCode 控制台实际创建的 key。",
        sources: [
            "https://www.relaxycode.com/",
            "https://www.relaxycode.com/blog/codex-gpt",
        ])

    private static let theRouter = ModelProviderTemplate.make(
        id: "therouter",
        name: "TheRouter.ai",
        aliases: ["the-router"],
        env: "THEROUTER_API_KEY",
        envAliases: ["ANTHROPIC_AUTH_TOKEN"],
        createURL: "https://dashboard.therouter.ai/",
        endpoints: [
            .init("OpenAI-compatible", "https://api.therouter.ai/v1"),
            .init("Anthropic Messages / Claude Code", "https://api.therouter.ai"),
        ],
        gates: ["登录 TheRouter.ai Dashboard", "创建 API key", "按用途设置消费额度"],
        permission: "模型调用使用 THEROUTER_API_KEY。Claude Code 仅把同一值映射为 ANTHROPIC_AUTH_TOKEN，并按官方要求将 ANTHROPIC_API_KEY 置空。管理 key 可创建和撤销其他 key，权限更高，不能代替普通模型调用 key 保存。",
        sources: [
            "https://therouter.ai/docs/quickstart/",
            "https://therouter.ai/docs/guides/guides/claude-code-integration/",
            "https://therouter.ai/docs/guides/guides/api-key-rotation/",
        ])
}
