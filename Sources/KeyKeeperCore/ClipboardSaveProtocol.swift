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
    /// Kept on the wire for older clients; the app no longer reads it.
    ///
    /// 0.3.3 required a copy AFTER the request (the 2026-09-13 incident: a minutes-old copy had
    /// been replaced by prose). 2026-09-14, yyt: "I had already copied it, then the agent told me
    /// to copy again, and I had closed the window." The current clipboard is now always what is
    /// saved, and the confirmation shows a masked preview and the copy time so the person can
    /// tell whether it is the right thing.
    public var useCurrentClipboard: Bool
    public var replaceExisting: Bool?
    public var expectedEd25519PublicKey: String?
    /// The caller's suggestion for a new credential: how it should be protected, and the last day
    /// the key works. Only with `create`. Neither is applied unless the person approves the save
    /// with the suggestion in front of them.
    public var security: SecurityLevel?
    public var expires: String?
    /// What the new credential is for, declared by the caller. Only with `create`.
    public var intent: UsageIntent?
    /// A `ProviderCatalog` id: the value is checked against the provider's key shape before
    /// anything is written, and verified with the provider's read-only request after saving.
    public var provider: String?
    public var isReplacement: Bool { replaceExisting == true }

    public init(credentialId: String, fieldName: String, create: Bool = false,
                expect: String? = nil, useCurrentClipboard: Bool = false,
                replaceExisting: Bool = false, expectedEd25519PublicKey: String? = nil,
                security: SecurityLevel? = nil, expires: String? = nil, intent: UsageIntent? = nil,
                provider: String? = nil) {
        self.credentialId = credentialId
        self.fieldName = fieldName
        self.create = create
        self.expect = expect
        self.useCurrentClipboard = useCurrentClipboard
        self.replaceExisting = replaceExisting ? true : nil
        self.expectedEd25519PublicKey = expectedEd25519PublicKey
        self.security = security
        self.expires = expires
        self.intent = intent
        self.provider = provider
    }

    public func validate() throws {
        if security != nil || expires != nil || intent != nil {
            guard create else { throw ClipboardSaveError.suggestionRequiresCreate }
        }
        if let expires {
            guard CredentialExpiry.normalize(expires) == expires else { throw ClipboardSaveError.invalidExpiry }
        }
        if isReplacement {
            guard !create, expect != nil else { throw ClipboardSaveError.invalidReplacement }
        }
        if let expectedEd25519PublicKey {
            guard isReplacement, expect == "base64:32", Data(base64Encoded: expectedEd25519PublicKey)?.count == 32 else {
                throw ClipboardSaveError.invalidExpectation
            }
        }
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
    case invalidProvider
    case invalidReplacement, targetValueChanged, identityMismatch
    case invalidSource, unsupportedSource, sourceParserUnavailable
    case invalidFile, fileChanged, wrongFieldType
    case invalidTarget, valueExists, targetNotFound, metadataChanged, clipboardChanged
    case invalidExpectation, shapeMismatch, clipboardNotCopiedYet, clipboardCopiedMoreThanOnce
    case emptyClipboard, busy, denied, expired, disconnected, storageUnavailable, metadataCommitFailed, staleGrants
    case reservedFieldName, suggestionRequiresCreate, invalidExpiry
    public var errorDescription: String? {
        switch self {
        case .invalidProvider: return "The provider or field does not match a built-in credential template. Nothing was read or saved. Run keykeeper providers show <id> to check the contract."
        case .invalidReplacement: return "Replacement requires an existing text field, --from-clipboard and --expect. Do not combine with --create."
        case .targetValueChanged: return "The existing value changed while approval was pending. Nothing was replaced. Start a fresh request."
        case .identityMismatch: return "The private key does not match the expected public key. Nothing was saved."
        case .invalidSource: return "Choose an owned regular UTF-8 Python file up to 1 MiB and an explicit Python symbol. No source contents were returned."
        case .unsupportedSource: return "The selected symbol is missing, ambiguous or unsupported. Only one top-level string literal or os.getenv/os.environ.get string default is accepted. Nothing was saved."
        case .sourceParserUnavailable: return "A supported Apple Python 3 parser is unavailable. No runtime was installed and no source code was executed."
        case .invalidFile: return "Choose an owned regular UTF-8 service-account JSON file (type, client_email and private_key required; at most 64 KiB). No contents were returned."
        case .fileChanged: return "The selected file changed or became unavailable. Nothing was saved. Select the intended file again."
        case .wrongFieldType: return "The import source does not match this field's type. Use a fresh credential ID for a different type."
        case .invalidTarget: return "Use a nonempty ID and field (letters, numbers, hyphens, underscores or dots; at most 128 UTF-8 bytes)."
        case .suggestionRequiresCreate: return "--security and --expires only apply with --create. Change an existing credential's protection in the KeyKeeper app, and its expiry with keykeeper edit --expires."
        case .invalidExpiry: return "Use --expires YYYY-MM-DD, the last day the key works (for example 2026-12-31). Nothing was read or saved."
        case .reservedFieldName: return "That field name would become an environment variable that decides how programs run (like PATH or DYLD_INSERT_LIBRARIES). Pick another field name. Nothing was read or saved."
        case .valueExists: return "A value already exists. Nothing was overwritten."
        case .targetNotFound: return "Secret field not found. Use --create only for a new credential ID."
        case .metadataChanged: return "Credential metadata changed. Check the target and retry."
        case .clipboardChanged: return "Clipboard changed while awaiting approval. Copy the intended key and try again."
        case .invalidExpectation: return "Use --expect base64[:BYTES], hex[:BYTES], bytes:N or chars:N. Nothing was read or saved."
        case .shapeMismatch: return "The value does not look like what you said to expect, so nothing was saved. Check what is actually on the clipboard."
        // No longer raised since 0.3.4; kept so older apps and clients still decode each other.
        case .clipboardNotCopiedYet: return "Nothing was saved. Copy the value and run the command again."
        case .clipboardCopiedMoreThanOnce: return "Nothing was saved. Copy the value and run the command again."
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
    /// After a save with a provider template: what the provider said about the key.
    public var validation: CredentialValidation?
    /// One sentence on a refusal, when the error code alone does not say enough ("OpenAI keys
    /// start with sk-; this value does not"). Never contains any part of the value.
    public var detail: String?
    public init(success: Bool, errorCode: ClipboardSaveError? = nil, shape: ValueShape? = nil,
                validation: CredentialValidation? = nil, detail: String? = nil) {
        self.success = success
        self.errorCode = errorCode
        self.shape = shape
        self.validation = validation
        self.detail = detail
    }
}
