import Foundation

/// Shared constructor for audited model gateways. Official client variables become field
/// names; compatibility variables are aliases of the same saved value, never duplicate keys.
enum ModelProviderTemplate {
    static func make(id: String, name: String, aliases: [String] = [], env: String,
                     envAliases: [String] = [], createURL: String, endpoints: [ProviderEndpoint],
                     gates: [String], permission: String, sources: [String],
                     expiry: String = "未确认统一有效期；以创建页面显示的实际日期为准，未知时不要猜测。",
                     shownOnce: Bool = false, prefixes: [String] = [],
                     context: [ProviderFieldTemplate] = []) -> ProviderTemplate {
        func field(_ variable: String) -> String {
            variable.lowercased().replacingOccurrences(of: "_", with: "-")
        }
        let primary = ProviderFieldTemplate(name: field(env), label: "API key", kind: .secretText,
            isPrimary: true, prefixes: prefixes,
            help: "只保存该供应商和本模板所列套餐的凭据；兼容协议不代表由 OpenAI 或 Anthropic 发行。",
            aliases: envAliases.isEmpty ? nil : envAliases.map(field))
        return ProviderTemplate(id: id, name: name, aliases: aliases, fieldName: primary.name,
            fields: [primary] + context, createURL: createURL, gates: gates,
            minimalPermission: permission, prefixes: prefixes, shownOnce: shownOnce,
            rotateURL: createURL, expiryNote: expiry, verified: "2026-09-15",
            endpoints: endpoints, sources: sources)
    }
}
