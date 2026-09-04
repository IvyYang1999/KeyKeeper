import Foundation

/// `keykeeper://add?label=OpenAI&fields=api-key,org-id&notes=...`
///
/// Lets an AI tool or a script hand the user a link that opens the "New Key Group" form
/// prefilled, instead of saying "go add it in the app" and leaving them to retype names.
enum DeepLink: Equatable {
    case addCredential(label: String?, fields: [String], notes: String?)

    static let scheme = "keykeeper"

    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        switch url.host?.lowercased() {
        case "add":
            let fields = (value("fields") ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return .addCredential(label: value("label"), fields: fields, notes: value("notes"))
        default:
            return nil
        }
    }

    /// The link an AI tool should offer when a credential is missing.
    static func addURL(label: String, fields: [String]) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "add"
        components.queryItems = [
            URLQueryItem(name: "label", value: label),
            URLQueryItem(name: "fields", value: fields.joined(separator: ",")),
        ]
        return components.url
    }
}
