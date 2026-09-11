import Foundation

public enum CredentialFileFormat: String, Codable, Sendable {
    case serviceAccountJSON

    public static let maximumBytes = 65_536

    /// Validate only the supported document shape, not trust, access or cryptographic validity.
    /// Return the original UTF-8 text, never a reserialized/normalized document.
    public func validate(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let value = String(data: data, encoding: .utf8), !value.contains("\0"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "service_account",
              let email = object["client_email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = object["private_key"] as? String, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ClipboardSaveError.invalidFile
        }
        return value
    }

    /// Cover individual JSON strings and PEM lines as well as the exact document.
    /// This is not a defense against arbitrary transformations performed by a child.
    public func redactionValues(for value: String) -> [String] {
        var result = [value]
        func visit(_ node: Any) {
            if let string = node as? String {
                if !string.isEmpty { result.append(string) }
                result += string.components(separatedBy: .newlines).filter { !$0.isEmpty }
            } else if let object = node as? [String: Any] { object.values.forEach(visit) }
            else if let array = node as? [Any] { array.forEach(visit) }
        }
        if let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) { visit(object) }
        return Array(Set(result))
    }
}

/// Contains only destination metadata and a local path, never document contents.
public struct FileImportRequest: Codable, Sendable, Equatable {
    public var target: ClipboardSaveRequest
    public var filePath: String
    public init(target: ClipboardSaveRequest, filePath: String) {
        self.target = target; self.filePath = filePath
    }
    public func validate() throws {
        try target.validate()
        guard filePath.hasPrefix("/"), filePath.utf8.count <= 4096,
              !filePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ClipboardSaveError.invalidFile
        }
    }
}
