import Foundation

/// Provider v2 templates added after the original ten. Complex providers describe the entire
/// credential bundle even though `keykeeper save --provider` imports only its primary secret;
/// public identifiers can then be added with `keykeeper edit --set` and confirmed in the app.
///
/// A missing `validation` is deliberate. Some providers require a signed request, a POST body,
/// a tenant-specific host, or even the secret in the URL. Treating a local shape check as online
/// verification would be worse than honestly reporting that runtime access is not verified.
enum AdditionalProviderCatalog {
    static let all: [ProviderTemplate] = google + ai + deployment + cloud + observability
        + publishing + messaging + auditedVariants

    private static let google: [ProviderTemplate] = [
        serviceAccount(
            id: "google-cloud", name: "Google Cloud", aliases: ["gcp", "google-service-account"],
            createURL: "https://console.cloud.google.com/iam-admin/serviceaccounts",
            gates: ["Sign in to Google Cloud", "Choose the project", "Create or select a dedicated service account", "Grant only the IAM roles the task needs", "Create a JSON key only when workload identity or local user credentials cannot be used"],
            permission: "Prefer Application Default Credentials or workload identity. If a downloaded key is unavoidable, use a dedicated service account with resource-level, task-specific IAM roles — never Owner or Editor."),
        serviceAccount(
            id: "ga4", name: "Google Analytics 4", aliases: ["google-analytics", "analytics"],
            createURL: "https://console.cloud.google.com/iam-admin/serviceaccounts",
            gates: ["Sign in to Google Cloud and choose a project", "Enable Google Analytics Data API", "Create a dedicated service account", "In GA4 Property access management, add its email"],
            permission: "GA4 property role = Viewer for reporting. Do not grant Editor or Administrator. Grant access only to the properties the task reads.",
            fields: [.init(name: "ga4-property-id", label: "GA4 Property ID", kind: .publicText,
                           help: "The numeric property ID, not the measurement ID that starts with G-.")]),
        serviceAccount(
            id: "firebase-admin", name: "Firebase Admin", aliases: ["firebase", "firebase-service-account"],
            createURL: "https://console.firebase.google.com/project/_/settings/serviceaccounts/adminsdk",
            gates: ["Sign in to Firebase and choose the project", "Open Project settings → Service accounts", "Generate a JSON key only for a trusted non-Google runtime"],
            permission: "Firebase Admin credentials are privileged. Prefer Application Default Credentials on Google-hosted runtimes; otherwise assign only the Google Cloud roles needed by the exact Firebase products in use."),
        serviceAccount(
            id: "search-console", name: "Google Search Console", aliases: ["gsc", "google-search-console"],
            createURL: "https://console.cloud.google.com/iam-admin/serviceaccounts",
            gates: ["Sign in to Google Cloud", "Enable Search Console API", "Create a dedicated service account", "Add its email as a user of the exact Search Console property"],
            permission: "Use Restricted user access when the task only reads search analytics. Grant Full only if URL inspection or property changes are explicitly required.",
            fields: [.init(name: "search-console-site-url", label: "Search Console property", kind: .publicText,
                           help: "The exact URL-prefix property or sc-domain value used by the API.")]),
    ]

    private static let ai: [ProviderTemplate] = [
        token(
            id: "openrouter", name: "OpenRouter", aliases: ["open-router"], field: "openrouter-api-key",
            createURL: "https://openrouter.ai/settings/keys",
            gates: ["Sign in to OpenRouter", "Choose the workspace", "Set a credit limit and optional expiration"],
            permission: "Create a separate key for this project with the lowest practical credit limit and an expiration.",
            shownOnce: true,
            validation: bearer("https://openrouter.ai/api/v1/key", description: "reads this key's limits and usage")),
        token(
            id: "deepseek", name: "DeepSeek", aliases: ["deep-seek"], field: "deepseek-api-key",
            createURL: "https://platform.deepseek.com/api_keys",
            gates: ["Sign in to the DeepSeek platform", "Create a separate API key", "Make sure the account has balance"],
            permission: "Keys have no per-key scopes. Use one key per project and revoke it independently.",
            shownOnce: false,
            validation: bearer("https://api.deepseek.com/models", description: "lists available models")),
        token(
            id: "groq", name: "Groq", field: "groq-api-key",
            createURL: "https://console.groq.com/keys",
            gates: ["Sign in to GroqCloud", "Choose the project", "Create an API key"],
            permission: "Create the key inside a project dedicated to this workload; project limits are the isolation boundary.",
            shownOnce: false,
            validation: bearer("https://api.groq.com/openai/v1/models", description: "lists available models")),
        token(
            id: "xai", name: "xAI", aliases: ["grok"], field: "xai-api-key",
            createURL: "https://console.x.ai/team/default/api-keys",
            gates: ["Sign in to the xAI Console", "Choose the team", "Create a key and configure spending limits"],
            permission: "Use a project-specific key with a spending limit. Do not reuse the team owner's general key.",
            shownOnce: true,
            validation: bearer("https://api.x.ai/v1/models", description: "lists available models")),
        token(
            id: "kimi", name: "Kimi Open Platform (China)", aliases: ["moonshot", "moonshot-cn"], field: "moonshot-api-key",
            createURL: "https://platform.moonshot.cn/console/api-keys",
            gates: ["Sign in to the China Kimi Open Platform", "Create a separate API key", "Make sure the pay-as-you-go account has balance"],
            permission: "This is a pay-as-you-go China Open Platform key for https://api.moonshot.cn/v1. It is not interchangeable with a Kimi Code membership key. Keys have no granular scopes; use one per project.",
            shownOnce: true,
            validation: bearer("https://api.moonshot.cn/v1/models", description: "lists available models")),
        token(
            id: "kimi-global", name: "Kimi API Platform (Global)", aliases: ["kimi-api", "moonshot-ai"], field: "moonshot-api-key",
            createURL: "https://platform.kimi.ai/console/account",
            gates: ["Sign in to the global Kimi API Platform", "Create a separate API key in the console", "Make sure the pay-as-you-go account has balance"],
            permission: "This is a pay-as-you-go global platform key for https://api.moonshot.ai/v1. It is not interchangeable with a Kimi Code membership key. Rate limits are shared at user level, so use separate keys for revocation rather than quota isolation.",
            shownOnce: true,
            validation: bearer("https://api.moonshot.ai/v1/models", invalidStatuses: [401], description: "lists available models")),
        token(
            id: "kimi-code", name: "Kimi Code", aliases: ["kimi-coding", "kimi-for-coding"], field: "kimi-api-key",
            createURL: "https://www.kimi.com/code/console",
            gates: ["Sign in to Kimi", "Activate a Kimi membership that includes Kimi Code", "Create a Kimi Code API key in the console (maximum five)", "Copy it before closing; the full key is shown once"],
            permission: "This membership key is only for supported coding tools. It is not interchangeable with a Kimi Open Platform key. Use https://api.kimi.com/coding/v1 for OpenAI-compatible tools or https://api.kimi.com/coding/ for Anthropic-compatible tools, and keep the tool's real User-Agent.",
            prefixes: ["sk-kimi-"], shownOnce: true),
        token(
            id: "minimax", name: "MiniMax Pay-as-you-go（中国）", field: "minimax-api-key",
            createURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
            gates: ["Sign in to MiniMax Open Platform", "Choose pay-as-you-go or Token Plan", "Create the matching kind of API key"],
            permission: "Keep pay-as-you-go and Token Plan keys separate; use the plan-specific key only with its matching endpoint.",
            shownOnce: false),
        token(
            id: "zhipu-cn", name: "智谱开放平台（中国）", aliases: ["zhipu", "bigmodel", "glm", "智谱", "zhipu-ai"], field: "zai-api-key", fieldAliases: ["zhipuai-api-key"],
            createURL: "https://open.bigmodel.cn/usercenter/apikeys",
            gates: ["Sign in to the China Zhipu Open Platform", "Create a general API key", "Activate pay-as-you-go billing or an API usage bundle if needed"],
            permission: "中国通用 API 使用 https://open.bigmodel.cn/api/paas/v4，按开放平台合同计费。Coding Plan 使用专用 endpoint 和套餐授权，不能按通用 API 路径假定扣套餐额度。每个项目单独建 key，保留独立撤销能力。",
            shownOnce: false),
        token(
            id: "zhipu-cn-coding", name: "智谱 GLM Coding Plan (China)", aliases: ["zhipu-coding", "zhipu-coding-plan", "glm-coding-cn"], field: "zai-api-key",
            createURL: "https://bigmodel.cn/coding-plan/personal/overview",
            gates: ["Sign in to the China Zhipu Open Platform", "Subscribe to an individual or team GLM Coding Plan", "For an individual plan, create the key under Personal Coding Plan → Plan Overview", "For a team plan, obtain the team key under Team Coding Plan → My Plan"],
            permission: "Use only with officially supported coding tools and the dedicated https://open.bigmodel.cn/api/coding/paas/v4 endpoint (or https://open.bigmodel.cn/api/anthropic for Anthropic Messages). Team Coding Plan keys are not interchangeable with other platform API keys.",
            shownOnce: false),
        token(
            id: "zai-global", name: "Z.AI API (Global)", aliases: ["zai", "z.ai", "zai-api"], field: "zai-api-key",
            createURL: "https://z.ai/manage-apikey/apikey-list",
            gates: ["Sign in to the global Z.AI Open Platform", "Create a general API key", "Activate pay-as-you-go billing or an API usage bundle if needed"],
            permission: "国际 Z.AI 通用 API 使用 https://api.z.ai/api/paas/v4。Coding Plan 的 endpoint、订阅授权与允许用途不同；不能因为格式相同就混用或假定套餐结算。不要把中国平台 key 迁到此模板。",
            shownOnce: false),
        token(
            id: "zai-global-coding", name: "Z.AI GLM Coding Plan", aliases: ["zai-coding", "zai-coding-plan", "glm-coding-global"], field: "zai-api-key",
            createURL: "https://z.ai/manage-apikey/apikey-list",
            gates: ["登录国际 Z.AI 平台", "确认个人或团队 Coding Plan 的订阅与 entitlement", "从对应套餐页面获取 key；团队使用团队套餐签发的 key"],
            permission: "仅用于允许的 coding 场景：OpenAI 协议 https://api.z.ai/api/coding/paas/v4，Anthropic 协议 https://api.z.ai/api/anthropic。团队 key 与其他平台 key not interchangeable；不把团队规则推断为个人 key 有独立前缀或长度。",
            shownOnce: false),
        token(
            id: "alibaba-bailian", name: "阿里云百炼 · 按量（北京）", aliases: ["dashscope", "qwen", "百炼"], field: "dashscope-api-key",
            createURL: "https://bailian.console.aliyun.com/?tab=model#/api-key",
            gates: ["Sign in to Alibaba Cloud and complete identity verification where required", "Choose the region and workspace", "Create an API key with custom model access"],
            permission: "Use a non-default workspace and Custom permission limited to the needed models and IP ranges. Keys and endpoints are region-specific.",
            shownOnce: false),
        token(
            id: "volcengine-ark", name: "火山方舟 · 按量（中国）", aliases: ["ark", "doubao", "火山方舟"], field: "ark-api-key",
            createURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apikey",
            gates: ["Sign in to Volcengine", "Activate Ark in the intended region", "Create a dedicated API key"],
            permission: "Use a dedicated key for this project and the matching regional Ark endpoint; avoid sharing an account-wide key across products.",
            shownOnce: false),
    ]

    private static let deployment: [ProviderTemplate] = [
        token(
            id: "neon", name: "Neon Personal API Key", field: "neon-api-key",
            createURL: "https://console.neon.tech/app/settings/api-keys",
            gates: ["Sign in to Neon", "Choose the organization and project", "Create an API key"],
            permission: "This item is a personal key and can reach projects visible to the person. Use the separate organization/project-scoped template for unattended agents.",
            shownOnce: true,
            validation: bearer("https://console.neon.tech/api/v2/projects", description: "lists only projects visible to the key"),
            fields: [.init(name: "neon-project-id", label: "Project ID", kind: .publicText, required: false)]),
        token(
            id: "railway", name: "Railway", field: "railway-token",
            createURL: "https://railway.com/dashboard",
            gates: ["Sign in to Railway", "Open the target Project → Environment → Tokens", "Create a project token for that one environment"],
            permission: "Use RAILWAY_TOKEN: a project token limited to one environment. Use the broader RAILWAY_API_TOKEN only for a task that genuinely spans projects or workspaces.",
            shownOnce: false),
        token(
            id: "render", name: "Render", field: "render-api-key",
            createURL: "https://dashboard.render.com/u/settings#api-keys",
            gates: ["Sign in to Render", "Open Account Settings → API Keys", "Create a separate API key"],
            permission: "Render API keys currently cover every workspace the user belongs to and have no scopes. Use a dedicated account or short-lived key for sensitive automation.",
            shownOnce: true,
            validation: bearer("https://api.render.com/v1/users", description: "reads the user associated with the key")),
        token(
            id: "netlify", name: "Netlify", field: "netlify-auth-token",
            createURL: "https://app.netlify.com/user/applications#personal-access-tokens",
            gates: ["Sign in to Netlify", "Open Applications → Personal access tokens", "Choose an expiration and SAML team access only if needed"],
            permission: "Personal tokens are account-wide. Set an expiration, do not opt into SAML team access unless the task needs that team, and prefer OAuth for a public integration.",
            shownOnce: true,
            validation: bearer("https://api.netlify.com/api/v1/user", description: "reads the authenticated user"),
            fields: [.init(name: "netlify-site-id", label: "Project ID", kind: .publicText, required: false)]),
        token(
            id: "flyio", name: "Fly.io", aliases: ["fly"], field: "fly-api-token",
            createURL: "https://fly.io/dashboard",
            gates: ["Sign in to Fly.io", "Use flyctl to create a token", "Choose the app, organization and expiration"],
            permission: "Prefer `fly tokens create deploy -a APP` for an app-scoped deploy token. Use an org token only when the task spans apps; do not use the short-lived all-powerful login token.",
            prefixes: ["FlyV1 "], shownOnce: true,
            fields: [.init(name: "fly-app-name", label: "App name", kind: .publicText, required: false)]),
    ]

    private static let cloud: [ProviderTemplate] = [
        ProviderTemplate(
            id: "aws", name: "AWS IAM · Long-lived access key", aliases: ["amazon-web-services"],
            fieldName: "aws-secret-access-key",
            fields: [
                .init(name: "aws-secret-access-key", label: "Secret access key", kind: .secretText,
                      isPrimary: true, minChars: 40),
                .init(name: "aws-access-key-id", label: "Access key ID", kind: .publicText,
                      prefixes: ["AKIA"], minChars: 20, regularExpression: #"^AKIA[A-Z0-9]{16}$"#),
                .init(name: "aws-region", label: "Default region", kind: .publicText, required: false),
            ],
            createURL: "https://console.aws.amazon.com/iam/home#/users",
            gates: ["Sign in to AWS", "Use IAM Identity Center or assume a role where possible", "If a key is unavoidable, create/select a dedicated IAM user", "Open its Security credentials and copy the pair once"],
            minimalPermission: "Prefer temporary role credentials. Never create a root access key. If long-lived keys are unavoidable, attach a least-privilege policy limited by action and resource, and set rotation reminders.",
            shownOnce: true,
            rotateURL: "https://console.aws.amazon.com/iam/home#/users",
            expiryNote: "Long-lived IAM access keys do not expire automatically; rotate and revoke explicitly.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "azure", name: "Azure Entra service principal · Client secret", aliases: ["microsoft-azure"],
            fieldName: "azure-client-secret",
            fields: [
                .init(name: "azure-client-secret", label: "Client secret", kind: .secretText, isPrimary: true),
                .init(name: "azure-client-id", label: "Application (client) ID", kind: .publicText),
                .init(name: "azure-tenant-id", label: "Directory (tenant) ID", kind: .publicText),
                .init(name: "azure-subscription-id", label: "Subscription ID", kind: .publicText, required: false),
            ],
            createURL: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
            gates: ["Sign in to Azure", "Create or select an app registration", "Create a client secret with the shortest suitable expiry", "Assign the service principal a role at the narrowest resource scope"],
            minimalPermission: "Prefer workload identity or managed identity. For a service principal, assign a task-specific role at resource or resource-group scope rather than subscription-wide Contributor.",
            shownOnce: true,
            rotateURL: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
            expiryNote: "Client secrets expire on the date chosen at creation.",
            verified: "2026-09-15"),
    ]

    private static let observability: [ProviderTemplate] = [
        token(
            id: "sentry", name: "Sentry Cloud · Organization Auth Token", field: "sentry-auth-token",
            createURL: "https://sentry.io/settings/",
            gates: ["Sign in to Sentry Cloud", "Open the target organization → Developer Settings → Auth", "Create an organization token with only the scopes required"],
            permission: "Prefer an organization token. Reporting needs org:read/project:read; release automation should use org:ci. Do not grant write/admin scopes unless the exact task requires them.",
            shownOnce: false,
            validation: bearer("https://sentry.io/api/0/organizations/", invalidStatuses: [401], description: "lists organizations visible to the token"),
            fields: [
                .init(name: "sentry-org", label: "Organization slug", kind: .publicText, required: false),
                .init(name: "sentry-project", label: "Project slug", kind: .publicText, required: false),
            ]),
        token(
            id: "posthog", name: "PostHog Cloud US · Personal API Key", field: "posthog-personal-api-key",
            createURL: "https://us.posthog.com/settings/user-api-keys",
            gates: ["Sign in to the correct PostHog region", "Create a personal API key", "Select only the required organization/project scopes"],
            permission: "Use a personal API key restricted to the target project and read-only scopes for analytics. The client-side project key is not an admin API credential.",
            prefixes: ["phx_"], shownOnce: true,
            fields: [.init(name: "posthog-host", label: "PostHog host", kind: .publicText,
                           help: "Use https://us.posthog.com for this template.")]),
    ]

    private static let publishing: [ProviderTemplate] = [
        token(
            id: "npm", name: "npm", field: "npm-token",
            createURL: "https://www.npmjs.com/settings/~/tokens",
            gates: ["Sign in to npm with 2FA", "Create a granular access token", "Choose packages/scopes, permissions, expiry and optional IP ranges"],
            permission: "Select only the packages or scopes needed. Prefer stage-only for reviewable automation, otherwise read-only or package-specific publish. Keep organization access at No access unless required.",
            prefixes: ["npm_"], shownOnce: true,
            validation: bearer("https://registry.npmjs.org/-/whoami", description: "reads the npm identity for this token")),
        token(
            id: "pypi", name: "PyPI · API token", field: "twine-password",
            createURL: "https://pypi.org/manage/account/token/",
            gates: ["Sign in to PyPI with 2FA", "Create an API token", "Choose the single project when it already exists"],
            permission: "Prefer Trusted Publishing (OIDC) for CI. When a stored token is unavoidable, use a project-scoped token; a pending trusted publisher can handle a first release without an account-wide token.",
            prefixes: ["pypi-"], minChars: 90,
            regularExpression: #"^pypi-[A-Za-z0-9_-]{85,}$"#, shownOnce: true,
            fields: [.init(name: "twine-username", label: "Twine username", kind: .publicText,
                           help: "Use the fixed value __token__ for API-token authentication.")]),
        token(
            id: "dockerhub", name: "Docker Hub · Personal access token", aliases: ["docker"], field: "docker-token",
            createURL: "https://app.docker.com/settings/personal-access-tokens",
            gates: ["Sign in to Docker Hub", "Create a personal or organization access token", "Choose repository permissions and expiry"],
            permission: "This item is a personal access token. Grant only Read or Write as needed and use `docker login --password-stdin`; Docker CLI does not automatically consume a generic token environment variable.",
            prefixes: ["dckr_pat_"], shownOnce: true,
            fields: [.init(name: "docker-username", label: "Docker username", kind: .publicText)]),
        token(
            id: "gitlab", name: "GitLab.com · Project access token", field: "gitlab-token",
            createURL: "https://gitlab.com/dashboard/projects",
            gates: ["Sign in to GitLab.com with 2FA/SSO", "Open the target project → Settings → Access tokens", "Select scopes and an expiration"],
            permission: "Use read_repository for inspection and add write_repository only for pushing. Repository-only tokens intentionally skip the /user API probe.",
            prefixes: ["glpat-"], shownOnce: true),
    ]

    private static let messaging: [ProviderTemplate] = [
        ProviderTemplate(
            id: "twilio", name: "Twilio API Key · US1",
            fieldName: "twilio-api-secret",
            fields: [
                .init(name: "twilio-api-secret", label: "API key secret", kind: .secretText, isPrimary: true),
                .init(name: "twilio-api-key", label: "API key SID", kind: .publicText,
                      prefixes: ["SK"], minChars: 34, regularExpression: #"^SK[0-9a-fA-F]{32}$"#),
                .init(name: "twilio-account-sid", label: "Account SID", kind: .publicText,
                      prefixes: ["AC"], minChars: 34, regularExpression: #"^AC[0-9a-fA-F]{32}$"#),
                .init(name: "twilio-region", label: "Region", kind: .publicText,
                      help: "This template creates US1 credentials. Record another region explicitly before using a regional endpoint."),
            ],
            createURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
            gates: ["Sign in to Twilio", "Choose the account/subaccount and region", "Create a Restricted API key where available", "Copy the secret once"],
            minimalPermission: "Use a Restricted API key with only the product actions required. Prefer a subaccount boundary. Do not use the account Auth Token for an application.",
            shownOnce: true,
            rotateURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
            expiryNote: "API keys remain valid until revoked.",
            verified: "2026-09-15"),
        token(
            id: "sendgrid", name: "Twilio SendGrid · US", field: "sendgrid-api-key",
            createURL: "https://app.sendgrid.com/settings/api_keys",
            gates: ["Sign in to SendGrid", "Create an API key", "Choose Custom Access"],
            permission: "Choose Custom Access and enable only Mail Send for a sending app. Do not use Full Access or Billing Access.",
            prefixes: ["SG."], shownOnce: true,
            fields: [.init(name: "sendgrid-api-base", label: "API base", kind: .publicText,
                           help: "Use https://api.sendgrid.com for this template; EU regional subusers need the EU template.")]),
        token(
            id: "mailgun", name: "Mailgun · Domain Sending Key", field: "mailgun-api-key",
            createURL: "https://app.mailgun.com/settings/api_security",
            gates: ["Sign in to Mailgun", "Open the exact sending domain → Domain Settings → Sending Keys", "Create a Domain Sending Key", "Record whether the domain is US or EU"],
            permission: "Use a Domain Sending Key for mail delivery; it can only send for one domain. Do not use the primary account API key unless management endpoints are explicitly required.",
            shownOnce: true,
            fields: [
                .init(name: "mailgun-domain", label: "Sending domain", kind: .publicText),
                .init(name: "mailgun-region", label: "Region", kind: .publicText),
            ]),
        token(
            id: "slack", name: "Slack Bot Token · Non-rotating", field: "slack-bot-token",
            createURL: "https://api.slack.com/apps",
            gates: ["Sign in to Slack", "Create or select an app", "Add only the required Bot Token Scopes", "Install the app to the intended workspace"],
            permission: "Use a bot token, not a user token. Add only method-specific bot scopes (for example chat:write); avoid user impersonation and legacy umbrella scopes.",
            prefixes: ["xoxb-"], shownOnce: false),
        ProviderTemplate(
            id: "feishu", name: "Feishu（中国）", aliases: ["飞书"],
            fieldName: "feishu-app-secret",
            fields: [
                .init(name: "feishu-app-secret", label: "App Secret", kind: .secretText, isPrimary: true),
                .init(name: "feishu-app-id", label: "App ID", kind: .publicText),
            ],
            createURL: "https://open.feishu.cn/app",
            gates: ["Sign in to Feishu Open Platform", "Create or select a custom app", "Add only required permissions and data scopes", "Publish/install the app in the intended tenant"],
            minimalPermission: "Use a custom app with only the exact API permissions and smallest data scope needed. Keep App ID as public metadata and App Secret as the only secret field.",
            shownOnce: false,
            rotateURL: "https://open.feishu.cn/app",
            expiryNote: "The App Secret remains valid until reset.",
            verified: "2026-09-15"),
        token(
            id: "telegram", name: "Telegram Bot", field: "telegram-bot-token",
            createURL: "https://t.me/BotFather",
            gates: ["Open the verified @BotFather chat", "Create a bot or request a new token", "Configure group privacy and admin rights separately"],
            permission: "A bot token grants full control of that bot and has no scopes. Create a dedicated bot and grant it only the chat membership/admin rights it needs.",
            regularExpression: #"^[0-9]+:[A-Za-z0-9_-]+$"#, shownOnce: false),
    ]

    /// Variants whose credential identity changes with region, billing plan, owner or protocol.
    /// They stay separate even when the bytes happen to look alike: picking the wrong one can
    /// reject a valid key, grant broader access, or charge the pay-as-you-go account by mistake.
    private static let aiVariants: [ProviderTemplate] = [
        token(
            id: "siliconflow-global", name: "SiliconFlow (Global)", aliases: ["siliconflow-com"],
            field: "siliconflow-api-key",
            createURL: "https://cloud.siliconflow.com/account/ak",
            gates: ["Sign in to the global SiliconFlow platform", "Create a separate API key", "Confirm the workflow uses api.siliconflow.com"],
            permission: "Global and China platform compatibility is not promised. Use a dedicated global key per project and the matching .com API base.",
            shownOnce: false,
            validation: bearer("https://api.siliconflow.com/v1/models", description: "lists models available on the global platform")),
        token(
            id: "minimax-global", name: "MiniMax Pay-as-you-go (Global)", field: "minimax-api-key",
            createURL: "https://platform.minimax.io/user-center/basic-information/interface-key",
            gates: ["Sign in to the global MiniMax platform", "Choose pay-as-you-go", "Create an API key in the global region"],
            permission: "Use only with the matching global pay-as-you-go account and base URL; it is not a Token Plan key.",
            shownOnce: false),
        token(
            id: "minimax-token-plan-cn", name: "MiniMax Token Plan（中国）", aliases: ["minimax-coding-plan-cn"],
            field: "minimax-api-key",
            createURL: "https://platform.minimaxi.com/subscribe/token-plan",
            gates: ["Sign in to the China MiniMax platform", "Subscribe to Token Plan", "Create the plan-specific key"],
            permission: "This subscription key is separate from pay-as-you-go. Use it only with the China Token Plan configuration.",
            prefixes: ["sk-cp-"], shownOnce: true),
        token(
            id: "minimax-token-plan-global", name: "MiniMax Token Plan (Global)", aliases: ["minimax-coding-plan-global"],
            field: "minimax-api-key",
            createURL: "https://platform.minimax.io/subscribe/token-plan",
            gates: ["Sign in to the global MiniMax platform", "Subscribe to Token Plan", "Create the plan-specific key"],
            permission: "This subscription key is separate from pay-as-you-go. Use it only with the global Token Plan configuration.",
            prefixes: ["sk-cp-"], shownOnce: true),
        token(
            id: "alibaba-bailian-coding-cn", name: "阿里云百炼 · Coding Plan（中国）", aliases: ["bailian-coding-plan"],
            field: "dashscope-api-key",
            createURL: "https://bailian.console.aliyun.com/",
            gates: ["Sign in to Alibaba Cloud", "Subscribe to Coding Plan in the intended workspace", "Create/copy the plan key and use the plan base URL"],
            permission: "A Coding Plan key/base is isolated from pay-as-you-go. Mixing them can charge the pay-as-you-go account.",
            prefixes: ["sk-sp-"], shownOnce: true),
        token(
            id: "alibaba-bailian-token-cn", name: "阿里云百炼 · Token Plan（中国）", aliases: ["bailian-token-plan"],
            field: "dashscope-api-key",
            createURL: "https://bailian.console.aliyun.com/",
            gates: ["Sign in to Alibaba Cloud", "Subscribe to Token Plan in the intended workspace", "Create/copy the plan key and use the plan base URL"],
            permission: "A Token Plan key/base is isolated from both Coding Plan and pay-as-you-go. Mixing them can use the wrong quota or billing path.",
            prefixes: ["sk-sp-"], shownOnce: true),
        token(
            id: "volcengine-ark-coding", name: "火山方舟 · Coding Plan（中国）", aliases: ["doubao-coding-plan"],
            field: "ark-api-key",
            createURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/codingplan",
            gates: ["Sign in to Volcengine", "Subscribe to Ark Coding Plan", "Create/copy the plan key"],
            permission: "Use this key only with the /api/coding/v3 base. The ordinary /api/v3 base can fall back to pay-as-you-go billing.",
            shownOnce: false),
    ]

    private static let platformVariants: [ProviderTemplate] = [
        token(
            id: "cloudflare-account", name: "Cloudflare Account API Token", field: "cloudflare-api-token",
            createURL: "https://dash.cloudflare.com/",
            gates: ["Sign in to Cloudflare", "Open the target account → Manage Account → Account API Tokens", "Create a least-privilege account-owned token and record the Account ID"],
            permission: "Use an account-owned token only for unattended account automation. Limit permissions/resources and set a TTL; it is distinct from a user token.",
            prefixes: ["cfat_"], shownOnce: true,
            fields: [.init(name: "cloudflare-account-id", label: "Account ID", kind: .publicText)]),
        token(
            id: "neon-org", name: "Neon Organization / Project-scoped API Key", field: "neon-api-key",
            createURL: "https://console.neon.tech/app",
            gates: ["Sign in to Neon", "Open the organization settings → API keys", "Create an organization key and restrict it to the target project where available"],
            permission: "Prefer a project-scoped organization key for an agent so it cannot see unrelated projects or create more keys.",
            prefixes: ["napi_"], shownOnce: true,
            validation: bearer("https://console.neon.tech/api/v2/projects", invalidStatuses: [401], description: "lists projects visible to this organization key"),
            fields: [.init(name: "neon-project-id", label: "Project ID", kind: .publicText)]),
        token(
            id: "railway-api", name: "Railway Account / Workspace API Token", field: "railway-api-token",
            createURL: "https://railway.com/account/tokens",
            gates: ["Sign in to Railway", "Choose Account Token or the intended Workspace token", "Name the token and record which owner issued it"],
            permission: "Use this broader API token only for work that genuinely spans projects. For one environment use the separate Railway Project token.",
            shownOnce: false),
        ProviderTemplate(
            id: "aws-sts", name: "AWS STS · Temporary credentials", aliases: ["aws-temporary"],
            fieldName: "aws-secret-access-key",
            fields: [
                .init(name: "aws-secret-access-key", label: "Secret access key", kind: .secretText, isPrimary: true),
                .init(name: "aws-access-key-id", label: "Access key ID", kind: .publicText,
                      prefixes: ["ASIA"], minChars: 20, regularExpression: #"^ASIA[A-Z0-9]{16}$"#),
                .init(name: "aws-session-token", label: "Session token", kind: .secretText),
                .init(name: "aws-region", label: "Default region", kind: .publicText, required: false),
                .init(name: "aws-credential-expires-at", label: "Expiration", kind: .publicText,
                      help: "Record the provider-issued expiration timestamp; STS credentials stop working after it."),
            ],
            createURL: "https://aws.amazon.com/iam/identity-center/",
            gates: ["Use IAM Identity Center or assume a least-privilege role", "Obtain one complete STS credential set", "Copy all three values and the issued expiration together"],
            minimalPermission: "Temporary credentials must include ASIA access-key ID, secret, session token and expiration. Prefer an AWS profile/credential provider chain when the tool supports it.",
            shownOnce: false,
            expiryNote: "STS credentials expire at the provider-issued timestamp; record it on the credential.",
            verified: "2026-09-15"),
        token(
            id: "pypi-test", name: "TestPyPI · API token", field: "twine-password",
            createURL: "https://test.pypi.org/manage/account/token/",
            gates: ["Sign in to the separate TestPyPI account", "Create an API token", "Choose the test project when it already exists"],
            permission: "TestPyPI accounts and tokens are separate from production PyPI. Prefer a project-scoped token.",
            prefixes: ["pypi-"], minChars: 90,
            regularExpression: #"^pypi-[A-Za-z0-9_-]{85,}$"#, shownOnce: true,
            fields: [.init(name: "twine-username", label: "Twine username", kind: .publicText,
                           help: "Use the fixed value __token__. Point the upload repository at TestPyPI.")]),
        token(
            id: "dockerhub-oat", name: "Docker Hub · Organization access token", field: "docker-token",
            createURL: "https://app.docker.com/admin",
            gates: ["Sign in as an organization owner", "Open the organization admin console → Access tokens", "Choose repositories, permissions and expiry"],
            permission: "Organization access tokens require an eligible subscription. Grant only exact repositories and Read/Write; avoid Delete unless explicitly needed.",
            prefixes: ["dckr_oat_"], shownOnce: true,
            fields: [.init(name: "docker-username", label: "Organization name", kind: .publicText)]),
        token(
            id: "posthog-eu", name: "PostHog Cloud EU · Personal API Key", field: "posthog-personal-api-key",
            createURL: "https://eu.posthog.com/settings/user-api-keys",
            gates: ["Sign in to PostHog Cloud EU", "Create a personal API key", "Select only the required organization/project scopes"],
            permission: "Restrict the personal API key to the target project and read-only scopes for analytics.",
            prefixes: ["phx_"], shownOnce: true,
            fields: [.init(name: "posthog-host", label: "PostHog host", kind: .publicText,
                           help: "Use https://eu.posthog.com for this template.")]),
        token(
            id: "sendgrid-eu", name: "Twilio SendGrid · EU regional subuser", field: "sendgrid-api-key",
            createURL: "https://app.sendgrid.com/settings/api_keys",
            gates: ["Sign in to the EU regional subuser", "Create an API key", "Choose Custom Access"],
            permission: "Choose Custom Access and enable only Mail Send. Use the EU API base for this regional subuser.",
            prefixes: ["SG."], shownOnce: true,
            fields: [.init(name: "sendgrid-api-base", label: "API base", kind: .publicText,
                           help: "Use https://api.eu.sendgrid.com.")]),
    ]

    private static let appleAndMessagingVariants: [ProviderTemplate] = [
        ProviderTemplate(
            id: "app-store-connect-individual", name: "App Store Connect · Individual API Key",
            aliases: ["asc-individual"], fieldName: "private-key",
            fields: [
                .init(name: "private-key", label: "Individual API private key (.p8)", kind: .secretFile,
                      isPrimary: true, fileFormat: .applePrivateKeyP8),
                .init(name: "key-id", label: "Key ID", kind: .publicText),
            ],
            createURL: "https://appstoreconnect.apple.com/access/integrations/api",
            gates: ["Sign in to App Store Connect", "Choose Individual API Keys", "Create the key", "Download the .p8 file immediately"],
            minimalPermission: "Individual keys use JWT subject user and no issuer ID. They cannot authenticate notarytool; use the team-key notary template for notarization.",
            shownOnce: true,
            rotateURL: "https://appstoreconnect.apple.com/access/integrations/api",
            expiryNote: "The key does not expire automatically; revoke it from App Store Connect.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "apple-notary-api-key", name: "Apple Notary · App Store Connect Team API Key",
            aliases: ["notarytool-api-key"], fieldName: "private-key",
            fields: [
                .init(name: "private-key", label: "Team API private key (.p8)", kind: .secretFile,
                      isPrimary: true, fileFormat: .applePrivateKeyP8),
                .init(name: "key-id", label: "Key ID", kind: .publicText),
                .init(name: "issuer-id", label: "Issuer ID", kind: .publicText),
            ],
            createURL: "https://appstoreconnect.apple.com/access/integrations/api",
            gates: ["Sign in as Account Holder or Admin", "Choose Team Keys and create a key allowed to submit notarization", "Download the .p8 file immediately"],
            minimalPermission: "notarytool accepts a team App Store Connect API key bundle. Individual App Store Connect keys are not accepted for notarization.",
            shownOnce: true,
            rotateURL: "https://appstoreconnect.apple.com/access/integrations/api",
            expiryNote: "The team key does not expire automatically; revoke it from App Store Connect.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "developer-id-installer", name: "Apple Developer ID Installer",
            aliases: ["productsign"], fieldName: "signing-identity",
            fields: [
                .init(name: "signing-identity", label: "Developer ID Installer identity", kind: .localIdentity,
                      isPrimary: true, help: "Use the full identity or certificate SHA-1; the private key stays in the macOS Keychain."),
            ],
            createURL: "https://developer.apple.com/account/resources/certificates/add",
            gates: ["Sign in to Apple Developer", "Choose Developer ID Installer", "Create it from a CSR whose private key remains on this Mac"],
            minimalPermission: "Use Installer only for signed installer packages. Application binaries require the separate Developer ID Application identity.",
            shownOnce: false,
            rotateURL: "https://developer.apple.com/account/resources/certificates/list",
            expiryNote: "The Apple-issued certificate has an expiration date; record it on the credential.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "lark", name: "Lark（Global）", aliases: ["larksuite"],
            fieldName: "lark-app-secret",
            fields: [
                .init(name: "lark-app-secret", label: "App Secret", kind: .secretText, isPrimary: true),
                .init(name: "lark-app-id", label: "App ID", kind: .publicText),
            ],
            createURL: "https://open.larksuite.com/app",
            gates: ["Sign in to Lark Open Platform", "Create/select a custom app", "Add only required permissions and data scopes", "Publish/install it in the intended tenant"],
            minimalPermission: "Use the global Lark console, LARK environment names and the open.larksuite.com API base. Feishu China credentials/endpoints are separate.",
            shownOnce: false,
            rotateURL: "https://open.larksuite.com/app",
            expiryNote: "Public docs do not promise one universal App Secret expiration policy; reset it explicitly when rotating.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "slack-oauth-rotating", name: "Slack OAuth · Rotating bot token bundle",
            aliases: ["slack-token-rotation"], fieldName: "slack-bot-token",
            fields: [
                .init(name: "slack-bot-token", label: "Rotating bot access token", kind: .secretText,
                      isPrimary: true, prefixes: ["xoxe.xoxb-"]),
                .init(name: "slack-refresh-token", label: "Refresh token", kind: .secretText,
                      prefixes: ["xoxe-"]),
                .init(name: "slack-client-id", label: "Client ID", kind: .publicText),
                .init(name: "slack-client-secret", label: "Client secret", kind: .secretText),
            ],
            createURL: "https://api.slack.com/apps",
            gates: ["Sign in to Slack", "Create/select an OAuth app", "Enable token rotation", "Install it and capture the complete access/refresh bundle"],
            minimalPermission: "Grant only method-specific bot scopes. Access tokens last 12 hours; the consuming workflow must exchange the refresh token and update this bundle safely.",
            prefixes: ["xoxe.xoxb-"], shownOnce: false,
            expiryNote: "Rotating Slack access tokens last 12 hours. The stored date is only a reminder; the caller must perform refresh-token rotation.",
            verified: "2026-09-15"),
    ]

    private static let auditedVariants = aiVariants + platformVariants + appleAndMessagingVariants

    private static func serviceAccount(id: String, name: String, aliases: [String], createURL: String,
                                       gates: [String], permission: String,
                                       fields: [ProviderFieldTemplate] = []) -> ProviderTemplate {
        let primary = ProviderFieldTemplate(
            name: "google-application-credentials", label: "Service-account JSON",
            kind: .secretFile, isPrimary: true, fileFormat: .serviceAccountJSON,
            help: "The complete downloaded JSON document; KeyKeeper materializes it as a temporary file for the child process.")
        return ProviderTemplate(
            id: id, name: name, aliases: aliases, fieldName: primary.name, fields: [primary] + fields,
            createURL: createURL, gates: gates, minimalPermission: permission,
            shownOnce: true,
            rotateURL: "https://console.cloud.google.com/iam-admin/serviceaccounts",
            expiryNote: "User-managed service-account keys usually remain valid until revoked, but organization policy can impose expiry. Record a date only when the console or policy shows one.",
            verified: "2026-09-15")
    }

    private static func token(id: String, name: String, aliases: [String] = [], field: String, fieldAliases: [String]? = nil,
                              createURL: String, gates: [String], permission: String,
                              prefixes: [String] = [], minChars: Int? = nil,
                              regularExpression: String? = nil, shownOnce: Bool,
                              validation: ProviderValidation? = nil,
                              fields: [ProviderFieldTemplate] = []) -> ProviderTemplate {
        let primary = ProviderFieldTemplate(name: field, label: "API token", kind: .secretText,
            isPrimary: true, prefixes: prefixes, minChars: minChars,
            regularExpression: regularExpression, aliases: fieldAliases)
        return ProviderTemplate(
            id: id, name: name, aliases: aliases, fieldName: field, fields: [primary] + fields,
            createURL: createURL, gates: gates, minimalPermission: permission,
            prefixes: prefixes, minChars: minChars, shownOnce: shownOnce,
            validation: validation, rotateURL: createURL,
            expiryNote: "No universal expiry policy was confirmed for this credential type. Record the date shown by the provider, or leave it unknown.",
            verified: "2026-09-15")
    }

    private static func bearer(_ url: String, invalidStatuses: [Int] = [401],
                               description: String) -> ProviderValidation {
        ProviderValidation(url: url, header: "Authorization", valuePrefix: "Bearer ",
                           invalidStatuses: invalidStatuses, description: description)
    }
}
