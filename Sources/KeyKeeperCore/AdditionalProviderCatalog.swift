import Foundation

/// Provider v2 templates added after the original ten. Complex providers describe the entire
/// credential bundle even though `keykeeper save --provider` imports only its primary secret;
/// public identifiers can then be added with `keykeeper edit --set` and confirmed in the app.
///
/// A missing `validation` is deliberate. Some providers require a signed request, a POST body,
/// a tenant-specific host, or even the secret in the URL. Treating a local shape check as online
/// verification would be worse than honestly reporting that runtime access is not verified.
enum AdditionalProviderCatalog {
    static let all: [ProviderTemplate] = google + ai + deployment + cloud + observability + publishing + messaging

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
            prefixes: ["sk-or-v1-"], minChars: 40, shownOnce: true,
            validation: bearer("https://openrouter.ai/api/v1/key", description: "reads this key's limits and usage")),
        token(
            id: "deepseek", name: "DeepSeek", aliases: ["deep-seek"], field: "deepseek-api-key",
            createURL: "https://platform.deepseek.com/api_keys",
            gates: ["Sign in to the DeepSeek platform", "Create a separate API key", "Make sure the account has balance"],
            permission: "Keys have no per-key scopes. Use one key per project and revoke it independently.",
            prefixes: ["sk-"], minChars: 32, shownOnce: true,
            validation: bearer("https://api.deepseek.com/models", description: "lists available models")),
        token(
            id: "groq", name: "Groq", field: "groq-api-key",
            createURL: "https://console.groq.com/keys",
            gates: ["Sign in to GroqCloud", "Choose the project", "Create an API key"],
            permission: "Create the key inside a project dedicated to this workload; project limits are the isolation boundary.",
            prefixes: ["gsk_"], minChars: 40, shownOnce: true,
            validation: bearer("https://api.groq.com/openai/v1/models", description: "lists available models")),
        token(
            id: "xai", name: "xAI", aliases: ["grok"], field: "xai-api-key",
            createURL: "https://console.x.ai/team/default/api-keys",
            gates: ["Sign in to the xAI Console", "Choose the team", "Create a key and configure spending limits"],
            permission: "Use a project-specific key with a spending limit. Do not reuse the team owner's general key.",
            prefixes: ["xai-"], minChars: 20, shownOnce: true,
            validation: bearer("https://api.x.ai/v1/models", description: "lists available models")),
        token(
            id: "kimi", name: "Kimi / Moonshot", aliases: ["moonshot"], field: "moonshot-api-key",
            createURL: "https://platform.moonshot.cn/console/api-keys",
            gates: ["Sign in to Moonshot Open Platform", "Create a separate API key", "Make sure the account has balance"],
            permission: "Keys have no granular scopes. Use one per project and revoke it when the project ends.",
            prefixes: ["sk-"], minChars: 20, shownOnce: true,
            validation: bearer("https://api.moonshot.cn/v1/models", description: "lists available models")),
        token(
            id: "minimax", name: "MiniMax", field: "minimax-api-key",
            createURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
            gates: ["Sign in to MiniMax Open Platform", "Choose pay-as-you-go or Token Plan", "Create the matching kind of API key"],
            permission: "Keep pay-as-you-go and Token Plan keys separate; use the plan-specific key only with its matching endpoint.",
            minChars: 20, shownOnce: true),
        token(
            id: "zhipu", name: "Zhipu AI", aliases: ["bigmodel", "glm", "智谱"], field: "zhipuai-api-key",
            createURL: "https://open.bigmodel.cn/usercenter/apikeys",
            gates: ["Sign in to the Zhipu Open Platform", "Create an API key", "Activate billing for paid models if needed"],
            permission: "Keys have no granular scopes. Create one per product so it can be revoked without affecting others.",
            minChars: 20, shownOnce: true,
            validation: bearer("https://open.bigmodel.cn/api/paas/v4/models", description: "lists available models")),
        token(
            id: "alibaba-bailian", name: "Alibaba Cloud Model Studio", aliases: ["dashscope", "qwen", "百炼"], field: "dashscope-api-key",
            createURL: "https://bailian.console.aliyun.com/?tab=model#/api-key",
            gates: ["Sign in to Alibaba Cloud and complete identity verification where required", "Choose the region and workspace", "Create an API key with custom model access"],
            permission: "Use a non-default workspace and Custom permission limited to the needed models and IP ranges. Keys and endpoints are region-specific.",
            prefixes: ["sk-"], minChars: 20, shownOnce: false),
        token(
            id: "volcengine-ark", name: "Volcengine Ark", aliases: ["ark", "doubao", "火山方舟"], field: "ark-api-key",
            createURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apikey",
            gates: ["Sign in to Volcengine", "Activate Ark in the intended region", "Create a dedicated API key"],
            permission: "Use a dedicated key for this project and the matching regional Ark endpoint; avoid sharing an account-wide key across products.",
            minChars: 20, shownOnce: true),
    ]

    private static let deployment: [ProviderTemplate] = [
        token(
            id: "neon", name: "Neon", field: "neon-api-key",
            createURL: "https://console.neon.tech/app/settings/api-keys",
            gates: ["Sign in to Neon", "Choose the organization and project", "Create an API key"],
            permission: "Prefer a project-scoped organization key for an agent. It cannot create other projects or keys and cannot see unrelated projects.",
            minChars: 20, shownOnce: true,
            validation: bearer("https://console.neon.tech/api/v2/projects", description: "lists only projects visible to the key"),
            fields: [.init(name: "neon-project-id", label: "Project ID", kind: .publicText, required: false)]),
        token(
            id: "railway", name: "Railway", field: "railway-token",
            createURL: "https://railway.com/account/tokens",
            gates: ["Sign in to Railway", "Open the target project's environment settings", "Create a project token"],
            permission: "Use RAILWAY_TOKEN: a project token limited to one environment. Use the broader RAILWAY_API_TOKEN only for a task that genuinely spans projects or workspaces.",
            minChars: 20, shownOnce: true),
        token(
            id: "render", name: "Render", field: "render-api-key",
            createURL: "https://dashboard.render.com/u/settings#api-keys",
            gates: ["Sign in to Render", "Open Account Settings → API Keys", "Create a separate API key"],
            permission: "Render API keys currently cover every workspace the user belongs to and have no scopes. Use a dedicated account or short-lived key for sensitive automation.",
            prefixes: ["rnd_"], minChars: 20, shownOnce: true,
            validation: bearer("https://api.render.com/v1/users", description: "reads the user associated with the key")),
        token(
            id: "netlify", name: "Netlify", field: "netlify-auth-token",
            createURL: "https://app.netlify.com/user/applications#personal-access-tokens",
            gates: ["Sign in to Netlify", "Open Applications → Personal access tokens", "Choose an expiration and SAML team access only if needed"],
            permission: "Personal tokens are account-wide. Set an expiration, do not opt into SAML team access unless the task needs that team, and prefer OAuth for a public integration.",
            minChars: 20, shownOnce: true,
            validation: bearer("https://api.netlify.com/api/v1/user", description: "reads the authenticated user"),
            fields: [.init(name: "netlify-site-id", label: "Project ID", kind: .publicText, required: false)]),
        token(
            id: "flyio", name: "Fly.io", aliases: ["fly"], field: "fly-api-token",
            createURL: "https://fly.io/dashboard",
            gates: ["Sign in to Fly.io", "Use flyctl to create a token", "Choose the app, organization and expiration"],
            permission: "Prefer `fly tokens create deploy -a APP` for an app-scoped deploy token. Use an org token only when the task spans apps; do not use the short-lived all-powerful login token.",
            prefixes: ["FlyV1 "], minChars: 20, shownOnce: true,
            fields: [.init(name: "fly-app-name", label: "App name", kind: .publicText, required: false)]),
    ]

    private static let cloud: [ProviderTemplate] = [
        ProviderTemplate(
            id: "aws", name: "Amazon Web Services", aliases: ["amazon-web-services"],
            fieldName: "aws-secret-access-key",
            fields: [
                .init(name: "aws-secret-access-key", label: "Secret access key", kind: .secretText,
                      isPrimary: true, minChars: 40),
                .init(name: "aws-access-key-id", label: "Access key ID", kind: .publicText,
                      prefixes: ["AKIA", "ASIA"], minChars: 20),
                .init(name: "aws-session-token", label: "Session token", kind: .secretText, required: false),
                .init(name: "aws-region", label: "Default region", kind: .publicText, required: false),
            ],
            createURL: "https://console.aws.amazon.com/iam/home#/security_credentials",
            gates: ["Sign in to AWS", "Use IAM Identity Center or assume a role where possible", "If a key is unavoidable, create it for a dedicated IAM principal", "Download/copy the secret once"],
            minimalPermission: "Prefer temporary role credentials. Never create a root access key. If long-lived keys are unavoidable, attach a least-privilege policy limited by action and resource, and set rotation reminders.",
            minChars: 40, shownOnce: true,
            rotateURL: "https://console.aws.amazon.com/iam/home#/security_credentials",
            expiryNote: "Long-lived IAM access keys do not expire automatically; STS session credentials do.",
            verified: "2026-09-15"),
        ProviderTemplate(
            id: "azure", name: "Microsoft Azure", aliases: ["microsoft-azure"],
            fieldName: "azure-client-secret",
            fields: [
                .init(name: "azure-client-secret", label: "Client secret", kind: .secretText, isPrimary: true, minChars: 16),
                .init(name: "azure-client-id", label: "Application (client) ID", kind: .publicText),
                .init(name: "azure-tenant-id", label: "Directory (tenant) ID", kind: .publicText),
                .init(name: "azure-subscription-id", label: "Subscription ID", kind: .publicText, required: false),
            ],
            createURL: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
            gates: ["Sign in to Azure", "Create or select an app registration", "Create a client secret with the shortest suitable expiry", "Assign the service principal a role at the narrowest resource scope"],
            minimalPermission: "Prefer workload identity or managed identity. For a service principal, assign a task-specific role at resource or resource-group scope rather than subscription-wide Contributor.",
            minChars: 16, shownOnce: true,
            rotateURL: "https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade",
            expiryNote: "Client secrets expire on the date chosen at creation.",
            verified: "2026-09-15"),
    ]

    private static let observability: [ProviderTemplate] = [
        token(
            id: "sentry", name: "Sentry", field: "sentry-auth-token",
            createURL: "https://sentry.io/settings/account/api/auth-tokens/",
            gates: ["Sign in to Sentry", "Prefer an organization internal integration", "Choose only the scopes required"],
            permission: "Prefer an organization token. Reporting needs org:read/project:read; release automation should use org:ci. Do not grant write/admin scopes unless the exact task requires them.",
            minChars: 20, shownOnce: true,
            validation: bearer("https://sentry.io/api/0/organizations/", invalidStatuses: [401], description: "lists organizations visible to the token"),
            fields: [
                .init(name: "sentry-org", label: "Organization slug", kind: .publicText, required: false),
                .init(name: "sentry-project", label: "Project slug", kind: .publicText, required: false),
            ]),
        token(
            id: "posthog", name: "PostHog", field: "posthog-personal-api-key",
            createURL: "https://us.posthog.com/settings/user-api-keys",
            gates: ["Sign in to the correct PostHog region", "Create a personal API key", "Select only the required organization/project scopes"],
            permission: "Use a personal API key restricted to the target project and read-only scopes for analytics. The client-side project key is not an admin API credential.",
            prefixes: ["phx_"], minChars: 20, shownOnce: true,
            fields: [.init(name: "posthog-host", label: "PostHog host", kind: .publicText, required: false,
                           help: "For example the US, EU or self-hosted API base URL.")]),
    ]

    private static let publishing: [ProviderTemplate] = [
        token(
            id: "npm", name: "npm", field: "npm-token",
            createURL: "https://www.npmjs.com/settings/~/tokens",
            gates: ["Sign in to npm with 2FA", "Create a granular access token", "Choose packages/scopes, permissions, expiry and optional IP ranges"],
            permission: "Select only the packages or scopes needed. Prefer stage-only for reviewable automation, otherwise read-only or package-specific publish. Keep organization access at No access unless required.",
            prefixes: ["npm_"], minChars: 20, shownOnce: true,
            validation: bearer("https://registry.npmjs.org/-/whoami", description: "reads the npm identity for this token")),
        token(
            id: "pypi", name: "PyPI", field: "twine-password",
            createURL: "https://pypi.org/manage/account/token/",
            gates: ["Sign in to PyPI with 2FA", "Create an API token", "Choose the single project when it already exists"],
            permission: "Use a project-scoped token. Account-wide tokens are only needed to upload a brand-new project's first release; replace them with a project token afterward.",
            prefixes: ["pypi-"], minChars: 20, shownOnce: true,
            fields: [.init(name: "twine-username", label: "Twine username", kind: .publicText,
                           help: "Use the fixed value __token__ for API-token authentication.")]),
        token(
            id: "dockerhub", name: "Docker Hub", aliases: ["docker"], field: "docker-token",
            createURL: "https://app.docker.com/settings/personal-access-tokens",
            gates: ["Sign in to Docker Hub", "Create a personal or organization access token", "Choose repository permissions and expiry"],
            permission: "Use an organization access token for shared automation and grant only the exact repositories: Pull for consumption, Push only for publishing, never Delete unless explicitly needed.",
            prefixes: ["dckr_pat_"], minChars: 20, shownOnce: true,
            fields: [.init(name: "docker-username", label: "Docker username or organization", kind: .publicText)]),
        token(
            id: "gitlab", name: "GitLab", field: "gitlab-token",
            createURL: "https://gitlab.com/-/user_settings/personal_access_tokens",
            gates: ["Sign in to GitLab with 2FA/SSO", "Choose project, group or personal token", "Select scopes and an expiration"],
            permission: "Prefer a project access token. Use read_api/read_repository for inspection and add write_repository only for pushing; avoid the full api scope unless required.",
            prefixes: ["glpat-"], minChars: 20, shownOnce: true,
            validation: ProviderValidation(url: "https://gitlab.com/api/v4/user", header: "PRIVATE-TOKEN",
                                           description: "reads the GitLab user for this token")),
    ]

    private static let messaging: [ProviderTemplate] = [
        ProviderTemplate(
            id: "twilio", name: "Twilio",
            fieldName: "twilio-api-secret",
            fields: [
                .init(name: "twilio-api-secret", label: "API key secret", kind: .secretText, isPrimary: true, minChars: 20),
                .init(name: "twilio-api-key", label: "API key SID", kind: .publicText, prefixes: ["SK"], minChars: 34),
                .init(name: "twilio-account-sid", label: "Account SID", kind: .publicText, prefixes: ["AC"], minChars: 34),
            ],
            createURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
            gates: ["Sign in to Twilio", "Choose the account/subaccount and region", "Create a Restricted API key where available", "Copy the secret once"],
            minimalPermission: "Use a Restricted API key with only the product actions required. Prefer a subaccount boundary. Do not use the account Auth Token for an application.",
            minChars: 20, shownOnce: true,
            rotateURL: "https://console.twilio.com/us1/account/keys-credentials/api-keys",
            expiryNote: "API keys remain valid until revoked.",
            verified: "2026-09-15"),
        token(
            id: "sendgrid", name: "Twilio SendGrid", field: "sendgrid-api-key",
            createURL: "https://app.sendgrid.com/settings/api_keys",
            gates: ["Sign in to SendGrid", "Create an API key", "Choose Custom Access"],
            permission: "Choose Custom Access and enable only Mail Send for a sending app. Do not use Full Access or Billing Access.",
            prefixes: ["SG."], minChars: 20, shownOnce: true),
        token(
            id: "mailgun", name: "Mailgun", field: "mailgun-api-key",
            createURL: "https://app.mailgun.com/settings/api_security",
            gates: ["Sign in to Mailgun", "Open the exact sending domain", "Create a Domain Sending Key"],
            permission: "Use a Domain Sending Key for mail delivery; it can only send for one domain. Do not use the primary account API key unless management endpoints are explicitly required.",
            minChars: 20, shownOnce: true,
            fields: [.init(name: "mailgun-domain", label: "Sending domain", kind: .publicText)]),
        token(
            id: "slack", name: "Slack", field: "slack-bot-token",
            createURL: "https://api.slack.com/apps",
            gates: ["Sign in to Slack", "Create or select an app", "Add only the required Bot Token Scopes", "Install the app to the intended workspace"],
            permission: "Use a bot token, not a user token. Add only method-specific bot scopes (for example chat:write); avoid user impersonation and legacy umbrella scopes.",
            prefixes: ["xoxb-"], minChars: 20, shownOnce: false),
        ProviderTemplate(
            id: "feishu", name: "Feishu / Lark", aliases: ["lark", "飞书"],
            fieldName: "feishu-app-secret",
            fields: [
                .init(name: "feishu-app-secret", label: "App Secret", kind: .secretText, isPrimary: true, minChars: 20),
                .init(name: "feishu-app-id", label: "App ID", kind: .publicText),
            ],
            createURL: "https://open.feishu.cn/app",
            gates: ["Sign in to Feishu Open Platform", "Create or select a custom app", "Add only required permissions and data scopes", "Publish/install the app in the intended tenant"],
            minimalPermission: "Use a custom app with only the exact API permissions and smallest data scope needed. Keep App ID as public metadata and App Secret as the only secret field.",
            minChars: 20, shownOnce: false,
            rotateURL: "https://open.feishu.cn/app",
            expiryNote: "The App Secret remains valid until reset.",
            verified: "2026-09-15"),
        token(
            id: "telegram", name: "Telegram Bot", field: "telegram-bot-token",
            createURL: "https://t.me/BotFather",
            gates: ["Open the verified @BotFather chat", "Create a bot or request a new token", "Configure group privacy and admin rights separately"],
            permission: "A bot token grants full control of that bot and has no scopes. Create a dedicated bot and grant it only the chat membership/admin rights it needs.",
            minChars: 30, shownOnce: false),
    ]

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
            expiryNote: "User-managed service-account keys normally do not expire automatically; revoke and rotate them explicitly.",
            verified: "2026-09-15")
    }

    private static func token(id: String, name: String, aliases: [String] = [], field: String,
                              createURL: String, gates: [String], permission: String,
                              prefixes: [String] = [], minChars: Int? = nil, shownOnce: Bool,
                              validation: ProviderValidation? = nil,
                              fields: [ProviderFieldTemplate] = []) -> ProviderTemplate {
        let primary = ProviderFieldTemplate(name: field, label: "API token", kind: .secretText,
            isPrimary: true, prefixes: prefixes, minChars: minChars)
        return ProviderTemplate(
            id: id, name: name, aliases: aliases, fieldName: field, fields: [primary] + fields,
            createURL: createURL, gates: gates, minimalPermission: permission,
            prefixes: prefixes, minChars: minChars, shownOnce: shownOnce,
            validation: validation, rotateURL: createURL,
            expiryNote: "Use the provider's shortest practical expiration when it offers one; otherwise revoke explicitly.",
            verified: "2026-09-15")
    }

    private static func bearer(_ url: String, invalidStatuses: [Int] = [401, 403],
                               description: String) -> ProviderValidation {
        ProviderValidation(url: url, header: "Authorization", valuePrefix: "Bearer ",
                           invalidStatuses: invalidStatuses, description: description)
    }
}
