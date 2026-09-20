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
    /// Explicitly add one secret field to an existing credential. This is never inferred from a
    /// misspelled field name: the person must see and approve the schema change.
    public var addField: Bool
    /// New durable rules to attach to this field after the approved write. Existing durable rules
    /// are always enforced too, even when a later caller omits this property.
    public var validation: CredentialFieldValidation?
    public var isReplacement: Bool { replaceExisting == true }
    public var hasPersistentValidation: Bool { validation?.isEmpty == false }

    private enum CodingKeys: String, CodingKey {
        case credentialId, fieldName, create, expect, useCurrentClipboard, replaceExisting,
             expectedEd25519PublicKey, security, expires, intent, provider, addField, validation
    }

    public init(credentialId: String, fieldName: String, create: Bool = false,
                expect: String? = nil, useCurrentClipboard: Bool = false,
                replaceExisting: Bool = false, expectedEd25519PublicKey: String? = nil,
                security: SecurityLevel? = nil, expires: String? = nil, intent: UsageIntent? = nil,
                provider: String? = nil, addField: Bool = false,
                validation: CredentialFieldValidation? = nil) {
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
        self.addField = addField
        self.validation = validation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        credentialId = try c.decode(String.self, forKey: .credentialId)
        fieldName = try c.decode(String.self, forKey: .fieldName)
        create = try c.decodeIfPresent(Bool.self, forKey: .create) ?? false
        expect = try c.decodeIfPresent(String.self, forKey: .expect)
        useCurrentClipboard = try c.decodeIfPresent(Bool.self, forKey: .useCurrentClipboard) ?? false
        replaceExisting = try c.decodeIfPresent(Bool.self, forKey: .replaceExisting)
        expectedEd25519PublicKey = try c.decodeIfPresent(String.self, forKey: .expectedEd25519PublicKey)
        security = try c.decodeIfPresent(SecurityLevel.self, forKey: .security)
        expires = try c.decodeIfPresent(String.self, forKey: .expires)
        intent = try c.decodeIfPresent(UsageIntent.self, forKey: .intent)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        addField = try c.decodeIfPresent(Bool.self, forKey: .addField) ?? false
        validation = try c.decodeIfPresent(CredentialFieldValidation.self, forKey: .validation)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(credentialId, forKey: .credentialId)
        try c.encode(fieldName, forKey: .fieldName)
        try c.encode(create, forKey: .create)
        try c.encodeIfPresent(expect, forKey: .expect)
        try c.encode(useCurrentClipboard, forKey: .useCurrentClipboard)
        try c.encodeIfPresent(replaceExisting, forKey: .replaceExisting)
        try c.encodeIfPresent(expectedEd25519PublicKey, forKey: .expectedEd25519PublicKey)
        try c.encodeIfPresent(security, forKey: .security)
        try c.encodeIfPresent(expires, forKey: .expires)
        try c.encodeIfPresent(intent, forKey: .intent)
        try c.encodeIfPresent(provider, forKey: .provider)
        if addField { try c.encode(true, forKey: .addField) }
        try c.encodeIfPresent(validation, forKey: .validation)
    }

    public func validate() throws {
        if security != nil || expires != nil || intent != nil {
            guard create else { throw ClipboardSaveError.suggestionRequiresCreate }
        }
        if let expires {
            guard CredentialExpiry.normalize(expires) == expires else { throw ClipboardSaveError.invalidExpiry }
        }
        if isReplacement {
            guard !create, !addField else { throw ClipboardSaveError.invalidReplacement }
        }
        if addField { guard !create else { throw ClipboardSaveError.invalidAddField } }
        if let expectedEd25519PublicKey {
            guard isReplacement, expect == "base64:32", Data(base64Encoded: expectedEd25519PublicKey)?.count == 32 else {
                throw ClipboardSaveError.invalidExpectation
            }
        }
        if let expect {
            guard ValueExpectation.parse(expect) != nil else { throw ClipboardSaveError.invalidExpectation }
        }
        if let validation {
            guard !validation.isEmpty else { throw ClipboardSaveError.invalidFieldValidation }
            do { _ = try validation.validated() }
            catch { throw ClipboardSaveError.invalidFieldValidation }
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
    case invalidProvider, invalidAddField
    case invalidReplacement, targetValueChanged, identityMismatch
    case invalidSource, unsupportedSource, sourceParserUnavailable
    case invalidFile, fileChanged, wrongFieldType
    case invalidTarget, valueExists, targetNotFound, metadataChanged, clipboardChanged
    case invalidExpectation, invalidFieldValidation, shapeMismatch, fieldValidationFailed, clipboardNotCopiedYet, clipboardCopiedMoreThanOnce
    case emptyClipboard, busy, denied, expired, disconnected, storageUnavailable
    case metadataCommitFailed, metadataCommitRolledBack, staleGrants
    case reservedFieldName, suggestionRequiresCreate, invalidExpiry
    case invalidEnvFile, emptyEnvFile, credentialExists
    public var errorDescription: String? {
        switch self {
        case .invalidProvider: return "The provider or field does not match a built-in credential template. Nothing was read or saved. Run keykeeper providers show <id> to check the contract."
        case .invalidAddField: return "--add-field requires an existing credential and a new secret field. Do not combine it with --create or --replace."
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
        case .invalidEnvFile: return "Give the absolute path of an owned .env file (named .env, .env.*, or *.env; at most 64 KiB). Nothing was read."
        case .emptyEnvFile: return "No importable variables: every line was empty, a comment, or a name that cannot become a field. Nothing was saved."
        case .credentialExists: return "A credential with that ID already exists. Pick another --id; nothing was changed."
        case .invalidExpiry: return "Use --expires YYYY-MM-DD, the last day the key works (for example 2026-12-31). Nothing was read or saved."
        case .reservedFieldName: return "That field name would become an environment variable that decides how programs run (like PATH or DYLD_INSERT_LIBRARIES). Pick another field name. Nothing was read or saved."
        case .valueExists: return "A value already exists. Nothing was overwritten."
        case .targetNotFound: return "Secret field not found. Use --create only for a new credential ID."
        case .metadataChanged: return "Credential metadata changed. Check the target and retry."
        case .clipboardChanged: return "Clipboard changed while awaiting approval. Copy the intended key and try again."
        case .invalidExpectation: return "Use --expect base64[:BYTES], hex[:BYTES], bytes:N or chars:N. Nothing was read or saved."
        case .invalidFieldValidation: return "Persistent validation needs --reject-url and/or short public --expect-prefix/--expect-suffix fragments. Nothing was read or saved."
        case .shapeMismatch: return "The value does not look like what you said to expect, so nothing was saved. Check what is actually on the clipboard."
        case .fieldValidationFailed: return "The value failed this field's persistent validation, so nothing was saved. Check that you copied the credential rather than a page or receiver URL."
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
        case .metadataCommitRolledBack: return "Credential metadata could not be committed, so KeyKeeper restored the field's prior state. Nothing from this request was kept."
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
