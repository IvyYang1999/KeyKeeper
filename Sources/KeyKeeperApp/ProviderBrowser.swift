import Foundation
import KeyKeeperCore

/// Navigation-only metadata. Never changes a provider's credential contract or stored binding.
enum ProviderCategory: String, CaseIterable, Identifiable {
    case models = "AI models"
    case gateways = "AI gateways"
    case cloud = "Cloud & databases"
    case development = "Development & publishing"
    case apple = "Apple services"
    case analytics = "Analytics & monitoring"
    case messaging = "Email & messaging"
    case payments = "Payments"
    var id: String { rawValue }
    var title: String { AppL10n.text(rawValue) }
}

enum ProviderBrowser {
    // Explicit membership prevents a new, unclassified provider silently appearing as an AI key.
    static let groups: [ProviderCategory: [String]] = [
        .models: ["openai", "anthropic", "gemini", "deepseek", "groq", "xai",
            "kimi", "kimi-global", "kimi-code", "minimax", "minimax-global",
            "minimax-token-plan-cn", "minimax-token-plan-global", "zhipu-cn", "zhipu-cn-coding",
            "zai-global", "zai-global-coding", "alibaba-bailian", "alibaba-bailian-coding-cn",
            "alibaba-bailian-token-cn", "alibaba-bailian-sg", "alibaba-bailian-us", "alibaba-bailian-hk",
            "volcengine-ark", "volcengine-ark-coding", "aws-bedrock-short-term", "aws-bedrock-long-term",
            "baidu-qianfan-cn", "baidu-qianfan-global", "baidu-qianfan-token-plan",
            "nvidia-api-catalog", "nvidia-ngc", "modelscope-cn", "modelscope-global", "novita-ai",
            "longcat", "stepfun-api", "stepfun-step-plan", "xiaomi-mimo-payg",
            "xiaomi-mimo-token-plan-cn", "xiaomi-mimo-token-plan-sg", "xiaomi-mimo-token-plan-eu"],
        .gateways: ["siliconflow", "siliconflow-global", "openrouter", "atlascloud", "atlascloud-coding-plan",
            "compshare-modelverse-cn", "compshare-modelverse-global", "compshare-agent-plan", "ccsub",
            "micu-claude", "micu-codex", "rightcode-codex", "cubence", "crazyrouter", "dmxapi-cn",
            "dmxapi-global", "dmxapi-ssvip", "aihubmix", "amux", "cherryin", "opencode-zen", "opencode-go",
            "pipellm", "relaxycode", "therouter"],
        .cloud: ["supabase", "vercel", "cloudflare", "cloudflare-account", "google-cloud", "firebase-admin",
            "neon", "neon-org", "railway", "railway-api", "render", "netlify", "flyio", "aws", "aws-sts", "azure"],
        .development: ["github", "gitlab", "npm", "pypi", "pypi-test", "dockerhub", "dockerhub-oat"],
        .apple: ["app-store-connect", "app-store-connect-individual", "apple-notary", "apple-notary-api-key",
            "apns", "developer-id", "developer-id-installer"],
        .analytics: ["ga4", "search-console", "sentry", "posthog", "posthog-eu"],
        .messaging: ["resend", "twilio", "sendgrid", "sendgrid-eu", "mailgun", "slack", "slack-oauth-rotating",
            "feishu", "lark", "telegram"],
        .payments: ["stripe"]
    ]

    static func results(query: String, category: ProviderCategory? = nil) -> [ProviderTemplate] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        let members = category.map { Set(groups[$0] ?? []) }
        return ProviderCatalog.all.filter { template in
            guard members?.contains(template.id) ?? true else { return false }
            let text = normalized(([template.id, template.name] + template.aliases).joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }

    static func movedHighlight(_ id: String?, by delta: Int, in rows: [ProviderTemplate]) -> String? {
        guard !rows.isEmpty else { return nil }
        let index = rows.firstIndex(where: { $0.id == id }) ?? 0
        return rows[min(max(index + delta, 0), rows.count - 1)].id
    }

    static func managementURL(for providerId: String?) -> URL? {
        guard let providerId, let template = ProviderCatalog.find(providerId) else { return nil }
        // Some templates create a service account in a different product, or start at a
        // certificate creation form. Management should open the console/list, never that form.
        let destinations = [
            "ga4": "https://analytics.google.com/analytics/web/",
            "search-console": "https://search.google.com/search-console",
            "aws-sts": "https://console.aws.amazon.com/console/home",
            "developer-id-installer": "https://developer.apple.com/account/resources/certificates/list"
        ]
        // Already-audited static page; opening a rotation page does not rotate any key.
        // No user/account/value interpolation, and no credentials attached to the browser URL.
        return safeWebURL(destinations[template.id] ?? template.rotateURL ?? template.createURL)
    }

    static func safeWebURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}
