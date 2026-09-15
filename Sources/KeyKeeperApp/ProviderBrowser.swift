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

/// One brand, one row. A regional console or a plan is a variant of the brand, not a brand:
/// yyt 2026-09-15 — 113 flat rows with five "阿里云百炼 · …" in a column is not a list a person
/// scans, and the template id under each name meant nothing to them.
struct ProviderFamily: Identifiable, Equatable {
    let id: String
    let name: String
    /// Brand words removed from the front of a member's template name to get its variant label.
    let strip: [String]
    let members: [ProviderTemplate]

    var isSingle: Bool { members.count == 1 }
    /// Artwork comes from the first member; ProviderMarks resolves variants to the shared mark.
    var markId: String { members.first?.id ?? id }

    /// "阿里云百炼 · 按量（中国香港）" → "按量 (中国香港)"; the brand is already the row above.
    func variantLabel(_ template: ProviderTemplate) -> String {
        ProviderBrowser.variantLabel(template.name, stripping: strip + [name])
    }
}

/// A brand that matched, and which of its variants did.
struct ProviderFamilyMatch: Identifiable, Equatable {
    let family: ProviderFamily
    let matched: [ProviderTemplate]
    var id: String { family.id }
}

/// What the picker lists, top to bottom, once search, category and expansion are applied.
enum ProviderPickerRow: Identifiable, Equatable {
    /// A brand with several variants; selecting it expands, it never binds.
    case family(ProviderFamily, matched: [ProviderTemplate], expanded: Bool)
    /// A bindable template. `nested` rows sit under their family; `variant` names the one
    /// shown when a family collapsed to a single match.
    case template(ProviderTemplate, family: ProviderFamily, nested: Bool, variant: String?)

    var id: String {
        switch self {
        case .family(let family, _, _): return "family:" + family.id
        case .template(let template, _, _, _): return "template:" + template.id
        }
    }
    var template: ProviderTemplate? {
        if case .template(let template, _, _, _) = self { return template }
        return nil
    }
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

    /// Brands with more than one template. Every other template is a brand of its own, named
    /// after the template. Order inside a brand is the order shown.
    static let familyTable: [(id: String, name: String, strip: [String], members: [String])] = [
        ("kimi", "Kimi", ["Kimi"], ["kimi", "kimi-global", "kimi-code"]),
        ("minimax", "MiniMax", ["MiniMax"], ["minimax", "minimax-global", "minimax-token-plan-cn", "minimax-token-plan-global"]),
        ("zhipu", "智谱 · Z.AI", ["智谱", "Z.AI"], ["zhipu-cn", "zhipu-cn-coding", "zai-global", "zai-global-coding"]),
        ("alibaba-bailian", "阿里云百炼", ["阿里云百炼"], ["alibaba-bailian", "alibaba-bailian-sg", "alibaba-bailian-us", "alibaba-bailian-hk", "alibaba-bailian-coding-cn", "alibaba-bailian-token-cn"]),
        ("volcengine-ark", "火山方舟", ["火山方舟"], ["volcengine-ark", "volcengine-ark-coding"]),
        ("aws-bedrock", "Amazon Bedrock", ["Amazon Bedrock"], ["aws-bedrock-long-term", "aws-bedrock-short-term"]),
        ("baidu-qianfan", "百度千帆", ["百度千帆", "Baidu AI Cloud Qianfan"], ["baidu-qianfan-cn", "baidu-qianfan-global", "baidu-qianfan-token-plan"]),
        ("nvidia", "NVIDIA", ["NVIDIA"], ["nvidia-api-catalog", "nvidia-ngc"]),
        ("modelscope", "ModelScope 魔搭", ["ModelScope 魔搭社区", "ModelScope"], ["modelscope-cn", "modelscope-global"]),
        ("stepfun", "StepFun 阶跃", ["StepFun"], ["stepfun-api", "stepfun-step-plan"]),
        ("xiaomi-mimo", "Xiaomi MiMo", ["Xiaomi MiMo"], ["xiaomi-mimo-payg", "xiaomi-mimo-token-plan-cn", "xiaomi-mimo-token-plan-sg", "xiaomi-mimo-token-plan-eu"]),
        ("siliconflow", "SiliconFlow 硅基流动", ["SiliconFlow"], ["siliconflow", "siliconflow-global"]),
        ("atlascloud", "Atlas Cloud", ["Atlas Cloud"], ["atlascloud", "atlascloud-coding-plan"]),
        ("compshare", "Compshare", ["Compshare"], ["compshare-modelverse-cn", "compshare-modelverse-global", "compshare-agent-plan"]),
        ("dmxapi", "DMXAPI", ["DMXAPI"], ["dmxapi-cn", "dmxapi-global", "dmxapi-ssvip"]),
        ("micu", "Micu API", ["Micu API"], ["micu-claude", "micu-codex"]),
        ("opencode", "OpenCode", ["OpenCode"], ["opencode-zen", "opencode-go"]),
        ("cloudflare", "Cloudflare", ["Cloudflare"], ["cloudflare", "cloudflare-account"]),
        ("neon", "Neon", ["Neon"], ["neon", "neon-org"]),
        ("railway", "Railway", ["Railway"], ["railway", "railway-api"]),
        ("aws", "AWS", ["AWS"], ["aws", "aws-sts"]),
        ("dockerhub", "Docker Hub", ["Docker Hub"], ["dockerhub", "dockerhub-oat"]),
        ("pypi", "PyPI", ["PyPI"], ["pypi", "pypi-test"]),
        ("app-store-connect", "App Store Connect", ["App Store Connect"], ["app-store-connect", "app-store-connect-individual"]),
        ("apple-notary", "Apple Notary", ["Apple Notary"], ["apple-notary", "apple-notary-api-key"]),
        ("developer-id", "Apple Developer ID", ["Apple Developer ID"], ["developer-id", "developer-id-installer"]),
        ("posthog", "PostHog", ["PostHog"], ["posthog", "posthog-eu"]),
        ("sendgrid", "Twilio SendGrid", ["Twilio SendGrid"], ["sendgrid", "sendgrid-eu"]),
        ("slack", "Slack", ["Slack"], ["slack", "slack-oauth-rotating"]),
        ("feishu", "飞书 · Lark", ["Feishu", "Lark"], ["feishu", "lark"]),
    ]

    static let families: [ProviderFamily] = {
        var byId: [String: ProviderTemplate] = [:]
        for template in ProviderCatalog.all { byId[template.id] = template }
        var claimed = Set<String>()
        var result: [ProviderFamily] = []
        for row in familyTable {
            let members = row.members.compactMap { byId[$0] }
            claimed.formUnion(row.members)
            result.append(ProviderFamily(id: row.id, name: row.name, strip: row.strip, members: members))
        }
        for template in ProviderCatalog.all where !claimed.contains(template.id) {
            result.append(ProviderFamily(id: template.id, name: template.name, strip: [], members: [template]))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    static func family(containing templateId: String) -> ProviderFamily? {
        families.first { $0.members.contains { $0.id == templateId } }
    }

    /// Search across brand names, template names, ids and old aliases; every word must match.
    static func familyMatches(query: String, category: ProviderCategory? = nil) -> [ProviderFamilyMatch] {
        let words = normalized(query).split(whereSeparator: \.isWhitespace)
        let members = category.map { Set(groups[$0] ?? []) }
        return families.compactMap { family in
            let matched = family.members.filter { template in
                guard members?.contains(template.id) ?? true else { return false }
                let text = normalized(([family.name, template.id, template.name] + template.aliases).joined(separator: " "))
                return words.allSatisfy { text.contains($0) }
            }
            return matched.isEmpty ? nil : ProviderFamilyMatch(family: family, matched: matched)
        }
    }

    /// Flat templates, for callers that do not group (CLI-style listing and older tests).
    static func results(query: String, category: ProviderCategory? = nil) -> [ProviderTemplate] {
        familyMatches(query: query, category: category).flatMap(\.matched)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// While searching, a brand whose variants all match is shown open so the person sees why;
    /// a brand with exactly one matching variant becomes that variant's row directly.
    static func rows(query: String, category: ProviderCategory? = nil, expanded: Set<String>) -> [ProviderPickerRow] {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        return familyMatches(query: query, category: category).flatMap { match -> [ProviderPickerRow] in
            let family = match.family
            if family.isSingle, let only = match.matched.first {
                return [.template(only, family: family, nested: false, variant: nil)]
            }
            if match.matched.count == 1, let only = match.matched.first {
                return [.template(only, family: family, nested: false, variant: family.variantLabel(only))]
            }
            let open = expanded.contains(family.id) || searching
            var rows: [ProviderPickerRow] = [.family(family, matched: match.matched, expanded: open)]
            if open {
                rows += match.matched.map { .template($0, family: family, nested: true, variant: family.variantLabel($0)) }
            }
            return rows
        }
    }

    static func variantLabel(_ name: String, stripping prefixes: [String]) -> String {
        var label = name
        for prefix in prefixes.sorted(by: { $0.count > $1.count }) where !prefix.isEmpty {
            if normalized(label).hasPrefix(normalized(prefix)) {
                label = String(label.dropFirst(prefix.count))
                break
            }
        }
        label = label.replacingOccurrences(of: "（", with: " (").replacingOccurrences(of: "）", with: ")")
        while let first = label.first, first == " " || first == "·" || first == "-" || first == ":" {
            label.removeFirst()
        }
        label = label.split(separator: " ").joined(separator: " ")
        return label.isEmpty ? name : label
    }

    /// The environment variable a program reads this key from; what a vibecoder recognises.
    static func environmentSummary(_ template: ProviderTemplate) -> String {
        let primary = template.primaryField.environmentNames.first ?? template.environmentName
        let others = template.fields.filter { $0.kind != .localIdentity }.count - 1
        return others > 0 ? "\(primary) +\(others)" : primary
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
    }

    static func movedHighlight<Row: Identifiable>(_ id: Row.ID?, by delta: Int, in rows: [Row]) -> Row.ID? {
        guard !rows.isEmpty else { return nil }
        let index = rows.firstIndex(where: { $0.id == id }) ?? 0
        return rows[min(max(index + delta, 0), rows.count - 1)].id
    }

    /// Where the key is created: the add flow sends the person here to get one.
    static func createURL(for providerId: String?) -> URL? {
        guard let providerId, let template = ProviderCatalog.find(providerId) else { return nil }
        return safeWebURL(template.createURL)
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
