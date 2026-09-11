import Foundation

/// Deliberately has no value, clipboard text, grant or claimed caller identity.
public struct ClipboardSaveRequest: Codable, Sendable, Equatable {
    public var credentialId: String
    public var fieldName: String
    public var create: Bool

    public init(credentialId: String, fieldName: String, create: Bool = false) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.create = create
    }

    public func validate() throws {
        for name in [credentialId, fieldName] {
            guard !name.isEmpty, name.utf8.count <= 128,
                  name == name.trimmingCharacters(in: .whitespacesAndNewlines),
                  name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }) else {
                throw ClipboardSaveError.invalidTarget
            }
        }
    }
}

public enum ClipboardSaveError: String, Error, Codable, Sendable, LocalizedError {
    case invalidFile, fileChanged, wrongFieldType
    case invalidTarget, valueExists, targetNotFound, metadataChanged, clipboardChanged
    case emptyClipboard, busy, denied, expired, disconnected, storageUnavailable, metadataCommitFailed, staleGrants
    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "Choose an owned regular UTF-8 service-account JSON file (type, client_email and private_key required; at most 64 KiB). No contents were returned."
        case .fileChanged: return "The selected file changed or became unavailable. Nothing was saved. Select the intended file again."
        case .wrongFieldType: return "The import source does not match this field's type. Use a fresh credential ID for a different type."
        case .invalidTarget: return "Use a nonempty ID and field (letters, numbers, hyphens, underscores or dots; at most 128 UTF-8 bytes)."
        case .valueExists: return "A value already exists. Nothing was overwritten."
        case .targetNotFound: return "Secret field not found. Use --create only for a new credential ID."
        case .metadataChanged: return "Credential metadata changed. Check the target and retry."
        case .clipboardChanged: return "Clipboard changed while awaiting approval. Copy the intended key and try again."
        case .emptyClipboard: return "Clipboard must contain nonempty text no larger than 64 KiB."
        case .busy: return "Another confirmation is pending. Finish it before requesting a save."
        case .denied: return "Save cancelled. Nothing was saved."
        case .expired: return "Save confirmation expired. Nothing was saved."
        case .disconnected: return "The requesting process disconnected. Nothing was saved."
        case .storageUnavailable: return "Storage cannot be safely updated. Check KeyKeeper; no automatic store recreation was attempted."
        case .metadataCommitFailed: return "The value was stored, but its metadata could not be committed. Do not retry or delete it; repair the metadata first."
        case .staleGrants: return "This ID has old read permissions. Choose a fresh credential ID; no permissions were changed."
        }
    }
}

public struct ClipboardSaveResponse: Codable, Sendable, Equatable {
    public var success: Bool
    public var errorCode: ClipboardSaveError?
    public init(success: Bool, errorCode: ClipboardSaveError? = nil) {
        self.success = success
        self.errorCode = errorCode
    }
}
