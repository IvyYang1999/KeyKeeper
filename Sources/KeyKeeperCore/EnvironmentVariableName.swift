import Foundation

/// How a field name becomes the environment variable `keykeeper run` injects.
/// Shared by the CLI (which injects) and the GUI (which previews the name).
public enum EnvironmentVariableName {
    /// "api-key" → "API_KEY", "base url" → "BASE_URL", "apiKey" → "APIKEY"
    public static func from(fieldName: String, prefix: String = "") -> String {
        let name = fieldName
            .uppercased()
            .map { $0.isLetter || $0.isNumber ? $0 : Character("_") }
            .map(String.init)
            .joined()
            .replacing(#/_{2,}/#, with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return prefix + name
    }
}
