import Foundation
import CryptoKit

public enum CredentialFileFormat: String, Codable, Sendable {
    case serviceAccountJSON
    case applePrivateKeyP8

    public static let maximumBytes = 65_536

    /// Validate only the supported document shape, not trust, access or cryptographic validity.
    /// Return the original UTF-8 text, never a reserialized/normalized document.
    public func validate(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= Self.maximumBytes,
              let value = String(data: data, encoding: .utf8), !value.contains("\0") else {
            throw ClipboardSaveError.invalidFile
        }
        switch self {
        case .serviceAccountJSON:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "service_account",
                  let email = object["client_email"] as? String,
                  !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let key = object["private_key"] as? String,
                  !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardSaveError.invalidFile
            }
        case .applePrivateKeyP8:
            // Apple API keys are P-256 signing keys in an unencrypted PKCS#8 PEM document.
            // Parsing the curve is important: matching BEGIN/END text alone accepted damaged,
            // RSA and unrelated documents, only to fail much later during a release.
            let label = ["PRIVATE", "KEY"].joined(separator: " ")
            guard value.contains("-----BEGIN \(label)-----"),
                  value.contains("-----END \(label)-----"),
                  (try? P256.Signing.PrivateKey(pemRepresentation: value)) != nil else {
                throw ClipboardSaveError.invalidFile
            }
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
        if self == .serviceAccountJSON,
           let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) { visit(object) }
        else if self == .applePrivateKeyP8 {
            result += value.components(separatedBy: .newlines).filter { !$0.isEmpty }
        }
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

/// The non-secret identity of a Google service-account file, for display only: which robot
/// account it is and which project it belongs to. The private key never enters this value.
public struct ServiceAccountSummary: Equatable, Sendable {
    public let clientEmail: String
    public let projectId: String?

    public static func parse(_ document: String) -> ServiceAccountSummary? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(document.utf8)) as? [String: Any],
              let email = (object["client_email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        let project = (object["project_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ServiceAccountSummary(clientEmail: email, projectId: project?.isEmpty == false ? project : nil)
    }
}
