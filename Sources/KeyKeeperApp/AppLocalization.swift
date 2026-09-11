import Foundation

/// UI-only language choice; credential data and executable commands are never translated.
enum AppL10n {
    static let preferenceName = "interfaceLanguage"
    static var language: String {
        let override = ProcessInfo.processInfo.environment["KEYKEEPER_UI_LANGUAGE"]
        return resolve(preference: override ?? UserDefaults.standard.string(forKey: preferenceName) ?? "system",
                       preferred: Locale.preferredLanguages)
    }
    static var locale: Locale { Locale(identifier: language) }
    static func locale(preference: String) -> Locale {
        Locale(identifier: resolve(preference: ProcessInfo.processInfo.environment["KEYKEEPER_UI_LANGUAGE"] ?? preference,
                                   preferred: Locale.preferredLanguages))
    }
    static func resolve(preference: String, preferred: [String]) -> String {
        if ["en", "zh-Hans"].contains(preference) { return preference }
        for candidate in preferred {
            if candidate.lowercased().hasPrefix("zh") { return "zh-Hans" }
            if candidate.lowercased().hasPrefix("en") { return "en" }
        }
        return "en"
    }
    static func text(_ template: String) -> String { render(template, language: language) }
    static func render(_ template: String, arguments: [String] = [], language: String) -> String {
        let translated = language == "zh-Hans" ? chinese[template] ?? chineseSupplement[template] ?? template : template
        let value = NSMutableString(string: translated)
        // Match only the template, backwards; user-provided arguments are never parsed again.
        for match in placeholderPattern.matches(in: translated, range: NSRange(location: 0, length: value.length)).reversed() {
            let ordinal = (translated as NSString).substring(with: match.range(at: 1))
            guard let index = Int(ordinal), arguments.indices.contains(index) else { continue }
            value.replaceCharacters(in: match.range, with: arguments[index])
        }
        return value as String
    }
    private static let placeholderPattern = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    static func placeholders(in value: String) -> [String] {
        placeholderPattern.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
            .map { (value as NSString).substring(with: $0.range) }.sorted()
    }
}

struct UILocalizedString: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    let template: String
    let arguments: [String]
    init(stringLiteral value: String) { template = value; arguments = [] }
    init(stringInterpolation: StringInterpolation) {
        template = stringInterpolation.template; arguments = stringInterpolation.arguments
    }
    struct StringInterpolation: StringInterpolationProtocol {
        var template = ""
        var arguments: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { template += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            template += "{\(arguments.count)}"; arguments.append(String(describing: value))
        }
    }
}

func L(_ value: UILocalizedString) -> String {
    AppL10n.render(value.template, arguments: value.arguments, language: AppL10n.language)
}
