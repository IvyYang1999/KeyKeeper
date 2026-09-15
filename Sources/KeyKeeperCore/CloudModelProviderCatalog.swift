import Foundation

/// Audited cloud/model credentials whose issuer, environment variable and routing contract
/// are documented by the provider. This catalog remains detached until the integration batch.
enum CloudModelProviderCatalog {
    static let all: [ProviderTemplate] = [
        ModelProviderTemplate.make(
            id: "aws-bedrock-short-term",
            name: "Amazon Bedrock · Short-term bearer key",
            aliases: ["bedrock short-term"],
            env: "AWS_BEARER_TOKEN_BEDROCK",
            createURL: "https://console.aws.amazon.com/bedrock",
            endpoints: [
                ProviderEndpoint("Bedrock Converse", "https://bedrock-runtime.{region}.amazonaws.com", region: "AWS Region"),
            ],
            gates: ["登录 AWS Management Console", "选择目标 AWS Region", "使用有 Bedrock 调用权限的 IAM 身份生成短期 key"],
            permission: "短期 key 继承生成它的 IAM principal 权限，并且只能用于生成时选择的 Region；只授予实际需要的 Bedrock 调用权限。",
            sources: [
                "https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html",
                "https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-reference.html",
            ],
            expiry: "有效期取 12 小时与生成它的 IAM principal 会话剩余时长中的较短者。",
            context: [regionField(name: "aws-region", label: "AWS Region")]),
        ModelProviderTemplate.make(
            id: "aws-bedrock-long-term",
            name: "Amazon Bedrock · Long-term bearer key",
            aliases: ["bedrock long-term"],
            env: "AWS_BEARER_TOKEN_BEDROCK",
            createURL: "https://console.aws.amazon.com/bedrock",
            endpoints: [
                ProviderEndpoint("Bedrock Converse", "https://bedrock-runtime.{region}.amazonaws.com", region: "AWS Region"),
            ],
            gates: ["登录 AWS Management Console", "选择目标 AWS Region", "确认仅用于探索", "选择到期时间后生成"],
            permission: "长期 key 由 IAM service-specific credential 支撑；仅用于探索，并在 Advanced permissions 中保留实际需要的 Bedrock 权限。",
            sources: [
                "https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys.html",
                "https://docs.aws.amazon.com/bedrock/latest/userguide/api-keys-reference.html",
            ],
            expiry: "有效至创建时配置的到期日期；具体日期必须以 AWS 创建结果为准。",
            context: [regionField(name: "aws-region", label: "AWS Region")]),
        ModelProviderTemplate.make(
            id: "baidu-qianfan-cn",
            name: "百度千帆（中国）",
            aliases: ["Baidu Qianfan", "Qianfan CN"],
            env: "QIANFAN_API_KEY",
            createURL: "https://console.bce.baidu.com/iam/",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://qianfan.baidubce.com/v2"),
            ],
            gates: ["登录百度智能云", "在安全认证的 API Key 页面创建 key", "仅添加实际调用的服务或 appid 权限"],
            permission: "只添加实际使用的千帆服务范围；若将 key 限定到 appid，调用时必须同时传入该 appid。",
            sources: [
                "https://cloud.baidu.com/doc/qianfan-docs/s/qm8qxemze",
                "https://cloud.baidu.com/doc/qianfan-api/s/ym9chdsy5",
                "https://cloud.baidu.com/doc/qianfan-docs/s/rm8r4tl9u",
            ],
            expiry: "千帆 V2 认证文档称控制台创建的普通 API Key 永久有效，直至用户撤销或更换。",
            context: [qianfanAppID]),
        ModelProviderTemplate.make(
            id: "baidu-qianfan-global",
            name: "Baidu AI Cloud Qianfan（International）",
            aliases: ["Qianfan Global", "Baidu Qianfan International"],
            env: "QIANFAN_API_KEY",
            createURL: "https://console.bce.baidu.com/iam/",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.baiduqianfan.ai/v1"),
            ],
            gates: ["登录国际文档所链接的百度智能云控制台", "创建或选择 API Key", "确认该账号与 key 可用于 International endpoint"],
            permission: "仅添加实际使用的服务范围；国际文档没有证明中国站与国际站账号或 key 可以互换。",
            sources: [
                "https://intl.cloud.baidu.com/en/doc/qianfan/s/qm8qxemze-intl-en",
            ],
            context: [qianfanAppID]),
        ModelProviderTemplate.make(
            id: "baidu-qianfan-token-plan",
            name: "百度千帆 · Token 福利包",
            aliases: ["Qianfan Token Plan"],
            env: "QIANFAN_TOKEN_PLAN_API_KEY",
            envAliases: ["QIANFAN_API_KEY"],
            createURL: "https://console.bce.baidu.com/iam/",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://qianfan.baidubce.com/v2"),
                ProviderEndpoint("Anthropic compatible", "https://qianfan.baidubce.com/anthropic"),
            ],
            gates: ["登录百度智能云千帆", "购买有效的 Token 福利包", "在控制台取得千帆通用 API Key"],
            permission: "Token 福利包使用千帆通用认证；不要把它与有独立 key 和独立路径的 Coding Plan 混用。",
            sources: [
                "https://cloud.baidu.com/doc/qianfan/s/Smoghsq3g",
                "https://cloud.baidu.com/doc/qianfan/s/bmovbdmzb",
                "https://cloud.baidu.com/doc/qianfan/s/imlg0beiu",
            ],
            expiry: "当前 Token 福利包文档列出的套餐有效期为 1 个月；API Key 本身是否随套餐到期未单独确认。"),
        ModelProviderTemplate.make(
            id: "nvidia-api-catalog",
            name: "NVIDIA API Catalog",
            aliases: ["NVIDIA hosted NIM", "build.nvidia.com"],
            env: "NVIDIA_API_KEY",
            createURL: "https://build.nvidia.com/settings/api-keys",
            endpoints: [
                ProviderEndpoint("OpenAI compatible hosted NIM", "https://integrate.api.nvidia.com/v1"),
            ],
            gates: ["登录 NVIDIA Build", "在 API Keys 页面生成 key", "创建后立即复制并安全保存；官方提示稍后可能无法再次查看完整 key", "接受所选模型要求的条款"],
            permission: "用于 NVIDIA 托管 NIM/API Catalog 推理；不要以 NGC personal/service key 替代。公开页面未确认统一的 key 权限粒度，也未保证 key 必定只显示一次。",
            sources: [
                "https://build.nvidia.com/settings/api-keys",
                "https://docs.nvidia.com/openshell/sandboxes/manage-providers",
                "https://docs.nvidia.com/nemo/retriever/latest/extraction/api-keys/",
                "https://docs.nvidia.com/nemo/curator/latest/curate-text/synthetic/llm-client",
            ]),
        ModelProviderTemplate.make(
            id: "nvidia-ngc",
            name: "NVIDIA NGC",
            aliases: ["NGC API key", "NVIDIA GPU Cloud"],
            env: "NGC_API_KEY",
            createURL: "https://org.ngc.nvidia.com/setup/api-keys",
            endpoints: [
                ProviderEndpoint("OCI/Docker Registry", "https://nvcr.io"),
            ],
            gates: ["登录正确的 NGC organization", "选择 Personal 或 Service Key", "选择到期日期、服务与所需 scope", "创建后立即安全保存"],
            permission: "Personal Key 仅选择所需 services；机器工作负载优先使用 Service Key，并按实体与动作收窄 scope。",
            sources: [
                "https://docs.nvidia.com/ngc/latest/ngc-user-guide.html",
                "https://docs.nvidia.com/nim/large-language-models/latest/get-started/configuration.html",
            ],
            expiry: "Personal Key 在创建时选择到期日期；Service Key 的统一到期合同未从本轮公开页面闭合。",
            shownOnce: true,
            context: [
                ProviderFieldTemplate(name: "ngc-org", label: "NGC organization", kind: .publicText, required: false),
                ProviderFieldTemplate(name: "ngc-team", label: "NGC team", kind: .publicText, required: false),
            ]),
        ModelProviderTemplate.make(
            id: "modelscope-cn",
            name: "ModelScope 魔搭社区（中国）",
            aliases: ["魔搭", "ModelScope CN"],
            env: "MODELSCOPE_API_TOKEN",
            envAliases: ["MODELSCOPE_API_KEY", "MODELSCOPE_SDK_TOKEN"],
            createURL: "https://modelscope.cn/my/access/token",
            endpoints: [
                ProviderEndpoint("ModelScope Hub/OpenAPI", "https://modelscope.cn/openapi/v1"),
            ],
            gates: ["登录 modelscope.cn", "在访问令牌页面创建适合用途的 token"],
            permission: "只下载公开或私有资产时使用 read 权限；仅在确实需要上传、部署或管理时选择 write 或更高权限。",
            sources: [
                "https://github.com/modelscope/modelscope_hub",
                "https://github.com/modelscope/modelscope-skills/blob/main/skills/ms-hub/SKILL.md",
                "https://github.com/modelscope/langchain-modelscope",
                "https://modelscope.cn/my/myaccesstoken",
            ]),
        ModelProviderTemplate.make(
            id: "modelscope-global",
            name: "ModelScope（Global）",
            aliases: ["ModelScope International", "ModelScope AI"],
            env: "MODELSCOPE_API_TOKEN",
            envAliases: ["MODELSCOPE_API_KEY"],
            createURL: "https://modelscope.ai/my/access/token",
            endpoints: [
                ProviderEndpoint("ModelScope Hub/OpenAPI", "https://modelscope.ai/openapi/v1"),
            ],
            gates: ["登录 modelscope.ai", "在 Global 站访问令牌页面创建 token", "确认客户端 endpoint 指向 Global 站"],
            permission: "中国站与 Global 站的账号、token 和内容目录独立；只授予当前 Hub/OpenAPI 操作所需的权限。",
            sources: [
                "https://github.com/modelscope/modelscope_hub",
                "https://github.com/modelscope/modelscope-skills/blob/main/skills/ms-hub/SKILL.md",
            ]),
        ModelProviderTemplate.make(
            id: "novita-ai",
            name: "Novita AI",
            aliases: ["Novita"],
            env: "NOVITA_API_KEY",
            createURL: "https://novita.ai/settings/key-management",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.novita.ai/openai"),
            ],
            gates: ["登录 Novita AI", "在 Key Management 点击 Add New Key", "立即将新 key 安全保存"],
            permission: "本轮公开 LiteLLM 与认证文档未确认可配置的统一权限 scope；不要虚构 scope。",
            sources: [
                "https://docs.novita.ai/guides/litellm",
                "https://docs.novita.ai/llms.txt",
            ]),
        longCat,
        ModelProviderTemplate.make(
            id: "stepfun-api",
            name: "StepFun API",
            aliases: ["StepFun pay-as-you-go", "阶跃星辰 API"],
            env: "STEP_API_KEY",
            createURL: "https://platform.stepfun.ai/interface-key",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.stepfun.ai/v1"),
                ProviderEndpoint("Anthropic compatible", "https://api.stepfun.ai"),
            ],
            gates: ["登录 StepFun Open Platform", "在 Account Management → Interface Keys 创建 key"],
            permission: "用于标准按量 API；标准 API 与 Step Plan 共用兼容协议路径，但 key、额度与计费产品不同，不要混用凭据。",
            sources: [
                "https://platform.stepfun.ai/docs/en/quickstart/overview",
                "https://platform.stepfun.ai/docs/en/api-reference/token-count",
                "https://platform.stepfun.ai/docs/en/api-reference/chat/messages-create",
            ]),
        ModelProviderTemplate.make(
            id: "stepfun-step-plan",
            name: "StepFun · Step Plan",
            aliases: ["Step Plan", "StepFun coding plan"],
            env: "STEP_API_KEY",
            createURL: "https://platform.stepfun.ai/interface-key",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.stepfun.ai/v1"),
                ProviderEndpoint("Anthropic compatible", "https://api.stepfun.ai"),
            ],
            gates: ["登录 StepFun Open Platform", "先订阅或激活 Step Plan", "再创建用于 Step Plan 的 API Key"],
            permission: "Step Plan 使用专属套餐/API Key，但与标准 API 共用兼容协议路径且无需额外前缀；调用前确认 key 所属套餐有效。",
            sources: [
                "https://platform.stepfun.ai/docs/en/step-plan/overview",
                "https://platform.stepfun.ai/docs/en/step-plan/quick-start",
            ],
            expiry: "未确认 API Key 自身的统一到期时间；套餐额度按月清零，套餐取消后服务持续至当前计费周期结束。"),
        ModelProviderTemplate.make(
            id: "xiaomi-mimo-payg",
            name: "Xiaomi MiMo · Pay-as-you-go",
            aliases: ["MiMo API", "小米 MiMo 按量"],
            env: "MIMO_API_KEY",
            createURL: "https://platform.xiaomimimo.com/",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.xiaomimimo.com/v1"),
                ProviderEndpoint("Anthropic compatible", "https://api.xiaomimimo.com/anthropic"),
            ],
            gates: ["登录 Xiaomi MiMo API Open Platform", "在 Console → API Keys 创建按量 key"],
            permission: "仅用于按量计费 API；不能用于 Token Plan endpoint。",
            sources: [
                "https://mimo.mi.com/docs/en-US/quick-start/faq/api-integration",
                "https://mimo.mi.com/docs/en-US/tokenplan/integration/tools-overview",
            ],
            prefixes: ["sk-"]),
        mimoTokenPlan(
            id: "xiaomi-mimo-token-plan-cn",
            name: "Xiaomi MiMo · Token Plan（中国）",
            aliases: ["MiMo Token Plan CN"],
            cluster: "中国",
            openAIBase: "https://token-plan-cn.xiaomimimo.com/v1",
            anthropicBase: "https://token-plan-cn.xiaomimimo.com/anthropic"),
        mimoTokenPlan(
            id: "xiaomi-mimo-token-plan-sg",
            name: "Xiaomi MiMo · Token Plan（新加坡）",
            aliases: ["MiMo Token Plan Singapore"],
            cluster: "新加坡",
            openAIBase: "https://token-plan-sgp.xiaomimimo.com/v1",
            anthropicBase: "https://token-plan-sgp.xiaomimimo.com/anthropic"),
        mimoTokenPlan(
            id: "xiaomi-mimo-token-plan-eu",
            name: "Xiaomi MiMo · Token Plan（欧洲）",
            aliases: ["MiMo Token Plan Europe"],
            cluster: "欧洲",
            openAIBase: "https://token-plan-ams.xiaomimimo.com/v1",
            anthropicBase: "https://token-plan-ams.xiaomimimo.com/anthropic"),
    ]

    private static let qianfanAppID = ProviderFieldTemplate(
        name: "qianfan-appid",
        label: "appid",
        kind: .publicText,
        required: false,
        help: "公开应用标识；仅当 API Key 被限制到特定 appid，或需要按应用区分用量时填写。")

    private static var longCat: ProviderTemplate {
        var template = ModelProviderTemplate.make(
            id: "longcat",
            name: "LongCat",
            aliases: ["LongCat AI"],
            env: "LONGCAT_API_KEY",
            createURL: "https://longcat.chat/platform/api_keys",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", "https://api.longcat.chat/openai"),
                ProviderEndpoint("Anthropic compatible", "https://api.longcat.chat/anthropic"),
            ],
            gates: ["注册并登录 LongCat API 开放平台", "在 API Keys 页面创建 key", "创建时立即复制并安全保存"],
            permission: "官方快速开始未规定默认环境变量；LONGCAT_API_KEY 只是 KeyKeeper 的本地注入名，客户端必须显式读取或配置它。",
            sources: [
                "https://longcat.chat/platform/docs/zh/",
                "https://longcat.chat/platform/api_keys",
            ],
            shownOnce: true)
        template.fields[0].help = "LONGCAT_API_KEY 是 KeyKeeper 本地注入名，不是 LongCat 官方默认环境变量；客户端必须显式读取或配置。"
        return template
    }

    private static func mimoTokenPlan(id: String, name: String, aliases: [String], cluster: String,
                                      openAIBase: String, anthropicBase: String) -> ProviderTemplate {
        ModelProviderTemplate.make(
            id: id,
            name: name,
            aliases: aliases,
            env: "MIMO_API_KEY",
            createURL: "https://platform.xiaomimimo.com/",
            endpoints: [
                ProviderEndpoint("OpenAI compatible", openAIBase, region: cluster),
                ProviderEndpoint("Anthropic compatible", anthropicBase, region: cluster),
            ],
            gates: ["登录 Xiaomi MiMo API Open Platform", "订阅有效的 Token Plan", "在 Token Plan 页面选择并确认 \(cluster)集群", "创建后立即安全保存专属 key"],
            permission: "仅用于 \(cluster)集群的 Token Plan；不能与按量 key 或其他集群 Base URL 混用。",
            sources: [
                "https://mimo.mi.com/docs/en-US/quick-start/faq/api-integration",
                "https://mimo.mi.com/docs/en-US/tokenplan/Token%20Plan/subscription",
                "https://mimo.mi.com/docs/en-US/tokenplan/Token%20Plan/quick-access",
            ],
            expiry: "仅在所订阅 Token Plan 套餐的有效期内可用；到期后需续订。",
            shownOnce: true,
            prefixes: ["tp-"],
            context: [regionField(name: "mimo-region", label: "Token Plan cluster")])
    }

    private static func regionField(name: String, label: String) -> ProviderFieldTemplate {
        ProviderFieldTemplate(
            name: name,
            label: label,
            kind: .publicText,
            help: "公开路由信息；保存时由用户明确填写。KeyKeeper 不从它推导或自动注入 Base URL。")
    }
}
