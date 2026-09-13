import Foundation

/// Deliberately has no value, clipboard text, grant or claimed caller identity.
public struct ClipboardSaveRequest: Codable, Sendable, Equatable {
    public var credentialId: String
    public var fieldName: String
    public var create: Bool
    /// What the caller expects the value to look like ("base64:32", "bytes:64", "hex:32",
    /// "chars:40"). Checked after approval, before anything is written.
    ///
    /// This exists because of a real incident: a value was copied to the clipboard, something
    /// else overwrote it before the save, and KeyKeeper stored a paragraph of prose as a signing
    /// key and reported success. Declaring the shape costs the caller nothing and can only ever
    /// cause a refusal, never a wider permission — so it is safe to accept from any process.
    public var expect: String?
    /// Accept whatever is already on the clipboard instead of waiting for a fresh copy.
    ///
    /// The default is to require a copy AFTER the request, because "whatever was lying on the
    /// clipboard when the command ran" is exactly what went wrong on 2026-09-13: a copy the user
    /// had made minutes earlier had already been replaced by something else. Ordinal freshness is
    /// all macOS offers — NSPasteboard exposes changeCount and no timestamp at all.
    public var useCurrentClipboard: Bool

    public init(credentialId: String, fieldName: String, create: Bool = false,
                expect: String? = nil, useCurrentClipboard: Bool = false) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.create = create
        self.expect = expect
        self.useCurrentClipboard = useCurrentClipboard
    }

    public func validate() throws {
        if let expect {
            guard ValueExpectation.parse(expect) != nil else { throw ClipboardSaveError.invalidExpectation }
        }
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
    case invalidSource, unsupportedSource, sourceParserUnavailable
    case invalidFile, fileChanged, wrongFieldType
    case invalidTarget, valueExists, targetNotFound, metadataChanged, clipboardChanged
    case invalidExpectation, shapeMismatch, clipboardNotCopiedYet, clipboardCopiedMoreThanOnce
    case emptyClipboard, busy, denied, expired, disconnected, storageUnavailable, metadataCommitFailed, staleGrants
    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "Choose an owned regular UTF-8 Python file up to 1 MiB and an explicit Python symbol. No source contents were returned."
        case .unsupportedSource: return "The selected symbol is missing, ambiguous or unsupported. Only one top-level string literal or os.getenv/os.environ.get string default is accepted. Nothing was saved."
        case .sourceParserUnavailable: return "A supported Apple Python 3 parser is unavailable. No runtime was installed and no source code was executed."
        case .invalidFile: return "Choose an owned regular UTF-8 service-account JSON file (type, client_email and private_key required; at most 64 KiB). No contents were returned."
        case .fileChanged: return "The selected file changed or became unavailable. Nothing was saved. Select the intended file again."
        case .wrongFieldType: return "The import source does not match this field's type. Use a fresh credential ID for a different type."
        case .invalidTarget: return "Use a nonempty ID and field (letters, numbers, hyphens, underscores or dots; at most 128 UTF-8 bytes)."
        case .valueExists: return "A value already exists. Nothing was overwritten."
        case .targetNotFound: return "Secret field not found. Use --create only for a new credential ID."
        case .metadataChanged: return "Credential metadata changed. Check the target and retry."
        case .clipboardChanged: return "Clipboard changed while awaiting approval. Copy the intended key and try again."
        case .invalidExpectation: return "Use --expect base64[:BYTES], hex[:BYTES], bytes:N or chars:N. Nothing was read or saved."
        case .shapeMismatch: return "The value does not look like what you said to expect, so nothing was saved. Check what is actually on the clipboard."
        case .clipboardNotCopiedYet: return "Nothing was copied after this request started, so nothing was saved. Copy the value now and run the command again — what was already on the clipboard is not accepted, because it may have been replaced since you copied it."
        case .clipboardCopiedMoreThanOnce: return "The clipboard was written more than once after this request started, so there is no way to tell which copy you meant. Nothing was saved. Run the command again and copy exactly once, or pass --use-current-clipboard if something else keeps writing to your clipboard."
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
    /// What was stored — or, on a refusal, what was on the clipboard instead. Counts and
    /// yes/no answers only; never the value, never any part of it.
    ///
    /// The caller learns the length and character class of something it never sees, which is a
    /// small disclosure. It is bounded by the user having just approved this exact save, and it
    /// buys the thing that was missing when a wrong paste went through unnoticed: the caller
    /// can check what it actually stored.
    public var shape: ValueShape?
    public init(success: Bool, errorCode: ClipboardSaveError? = nil, shape: ValueShape? = nil) {
        self.success = success
        self.errorCode = errorCode
        self.shape = shape
    }
}
