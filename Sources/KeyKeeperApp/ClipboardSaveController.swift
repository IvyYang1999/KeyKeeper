import AppKit
import KeyKeeperCore
import CryptoKit

@MainActor protocol ClipboardSaveSource: AnyObject {
    var changeCount: Int { get }
    /// True for the shared system clipboard, where "what is there now" is not evidence that the
    /// user put it there for this request. The browser and file sources own their own content.
    var requiresFreshCopy: Bool { get }
    var fileFormat: CredentialFileFormat? { get }
    var displayFilePath: String? { get }
    var pythonSymbol: String? { get }
    func readText() throws -> String?
    func clearIfUnchanged(since count: Int)
}

extension ClipboardSaveSource {
    var requiresFreshCopy: Bool { false }
    var fileFormat: CredentialFileFormat? { nil }
    var displayFilePath: String? { nil }
    var pythonSymbol: String? { nil }
}

@MainActor final class SystemClipboardSaveSource: ClipboardSaveSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var requiresFreshCopy: Bool { true }
    func readText() -> String? { NSPasteboard.general.string(forType: .string) }
    func clearIfUnchanged(since count: Int) { SecretPasteboard.clearIfUnchanged(since: count) }
}

/// One single-use request at a time. No queue: a queued request could capture the wrong copy.
@MainActor final class ClipboardSaveController {
    struct Presentation {
        let request: ClipboardSaveRequest
        let callerName: String
        var fromBrowser = false
        var filePath: String?
        var pythonSymbol: String?
        var expiresAt: Date?
    }
    private struct Pending {
        let id: UUID
        let presentation: Presentation
        let metadata: Data
        let changeCount: Int
        let valueFingerprint: Data?
        let source: ClipboardSaveSource
        let expiresAt: Date
        let isConnected: () -> Bool
        let completion: (ClipboardSaveResponse) -> Void
    }
    private let service: KeychainCredentialService
    private let metaStore: MetaStore
    private let clipboard: ClipboardSaveSource
    private let now: () -> Date
    private let present: (Presentation, @escaping (Bool) -> Void) -> Void
    private let dismiss: () -> Void
    private var pending: Pending?
    private var timer: Timer?
    private var isPresented = false
    var isPending: Bool { pending != nil }

    init(service: KeychainCredentialService, metaStore: MetaStore = .default,
         clipboard: ClipboardSaveSource? = nil, now: @escaping () -> Date = Date.init,
         present: ((Presentation, @escaping (Bool) -> Void) -> Void)? = nil,
         dismiss: (() -> Void)? = nil) {
        self.service = service; self.metaStore = metaStore
        self.clipboard = clipboard ?? SystemClipboardSaveSource(); self.now = now
        let window = ClipboardSaveWindow()
        self.present = present ?? { window.show($0, decide: $1) }
        self.dismiss = dismiss ?? { window.dismiss() }
    }

    func receive(_ request: ClipboardSaveRequest, callerName: String,
                 isConnected: @escaping () -> Bool,
                 source: ClipboardSaveSource? = nil, deferPresentation: Bool = false,
                 completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard pending == nil else { completion(.init(success: false, errorCode: .busy)); return }
        do {
            try request.validate()
            if request.isReplacement || request.expectedEd25519PublicKey != nil {
                guard source == nil else { throw ClipboardSaveError.invalidReplacement }
            }
            guard isConnected() else { throw ClipboardSaveError.disconnected }
            let metadata = try metaStore.load()
            try validateTarget(request, metadata: metadata, fileFormat: source?.fileFormat)
            let expiresAt = now().addingTimeInterval(90)
            let info = Presentation(request: request, callerName: callerName,
                fromBrowser: source != nil && source?.displayFilePath == nil,
                filePath: source?.displayFilePath, pythonSymbol: source?.pythonSymbol,
                expiresAt: expiresAt)
            let source = source ?? clipboard
            let id = UUID()
            pending = Pending(id: id, presentation: info, metadata: try canonical(metadata),
                changeCount: source.changeCount,
                valueFingerprint: request.isReplacement ? try service.valueFingerprint(
                    credentialId: request.credentialId, fieldName: request.fieldName) : nil,
                source: source, expiresAt: expiresAt,
                isConnected: isConnected, completion: completion)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.expireIfNeeded() }
            }
            if !deferPresentation { presentPending() }
        } catch {
            completion(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable))
        }
    }

    func presentPending() {
        expireIfNeeded()
        guard let pending, !isPresented else { return }
        isPresented = true
        present(pending.presentation) { [weak self] approved in
            guard self?.pending?.id == pending.id else { return }
            self?.resolve(approved: approved)
        }
    }

    func expireIfNeeded() {
        guard let pending else { return }
        if now() >= pending.expiresAt { finish(.init(success: false, errorCode: .expired)) }
        else if !pending.isConnected() { finish(.init(success: false, errorCode: .disconnected)) }
    }

    func cancel() { if pending != nil { finish(.init(success: false, errorCode: .denied)) } }

    func resolve(approved: Bool) {
        expireIfNeeded()
        guard let pending, isPresented else { return }
        guard approved else { cancel(); return }
        // Reported only when a declared shape did not match: the caller needs to know what it
        // nearly stored. Every other failure says nothing about the clipboard.
        var shapeOnFailure: ValueShape?
        do {
            let clipboard = pending.source
            let request = pending.presentation.request
            var metadata = try metaStore.load()
            guard try canonical(metadata) == pending.metadata else { throw ClipboardSaveError.metadataChanged }
            try validateTarget(request, metadata: metadata, fileFormat: clipboard.fileFormat)
            let changed: ClipboardSaveError = clipboard.displayFilePath == nil ? .clipboardChanged : .fileChanged
            // Two different questions, and the old code asked only the second one.
            //   1. Did the user copy something FOR this request? Ordinal freshness: the count must
            //      have moved exactly once since the request started. Extra revisions, including
            //      those from clipboard managers, are ambiguous and therefore refused.
            //   2. Did the content hold still while we read it? That is the equality check, taken
            //      around the read itself rather than against the request's own baseline.
            let requiresFreshCopy = clipboard.requiresFreshCopy && !request.useCurrentClipboard
            if requiresFreshCopy {
                // Exactly one write, not "at least one": the count is an integer, so
                // baseline + 1 means one copy happened and nothing has touched the clipboard
                // since. "At least one" would be weaker than the old rule — copy the key, then
                // copy something else, and it would store the something else, which is the
                // accident this is meant to prevent. changeCount can say whether the clipboard
                // changed; it cannot say which of two copies you meant, so refuse and let the
                // person redo it.
                switch clipboard.changeCount - pending.changeCount {
                case 0: throw ClipboardSaveError.clipboardNotCopiedYet
                case 1: break
                default: throw ClipboardSaveError.clipboardCopiedMoreThanOnce
                }
            } else {
                guard clipboard.changeCount == pending.changeCount else { throw changed }
            }
            let countAtRead = clipboard.changeCount
            // No pasteboard string is fetched until the target and one-time approval are validated.
            guard let value = try clipboard.readText(), value.utf8.count <= 65_536,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardSaveError.emptyClipboard
            }
            guard clipboard.changeCount == countAtRead else { throw changed }
            // What the caller said to expect, checked before a single byte is written. The
            // clipboard is a shared, racy channel: what the user copied is not always what is
            // there when the save runs, and "saved" must not mean "stored whatever was there".
            let shape = ValueShape.of(value)
            if let expect = request.expect {
                guard let expectation = ValueExpectation.parse(expect) else {
                    throw ClipboardSaveError.invalidExpectation
                }
                guard expectation.matches(shape) else {
                    shapeOnFailure = shape
                    throw ClipboardSaveError.shapeMismatch
                }
            }
            guard now() < pending.expiresAt else { throw ClipboardSaveError.expired }
            guard pending.isConnected() else { throw ClipboardSaveError.disconnected }
            if let expected = request.expectedEd25519PublicKey {
                guard let seed = Data(base64Encoded: value), seed.count == 32,
                      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
                      key.publicKey.rawRepresentation == Data(base64Encoded: expected) else {
                    throw ClipboardSaveError.identityMismatch
                }
            }
            if request.isReplacement {
                guard let fingerprint = pending.valueFingerprint else { throw ClipboardSaveError.invalidReplacement }
                guard now() < pending.expiresAt else { throw ClipboardSaveError.expired }
                guard pending.isConnected() else { throw ClipboardSaveError.disconnected }
                try service.replaceExisting(credentialId: request.credentialId, fieldName: request.fieldName,
                    value: value, expectedFingerprint: fingerprint)
            } else {
                try service.saveMissing(credentialId: request.credentialId, fieldName: request.fieldName, value: value)
            }
            if request.create {
                let date = ISO8601DateFormatter().string(from: now())
                metadata.credentials[request.credentialId] = Credential(label: request.credentialId,
                    notes: "", links: [], fields: [request.fieldName: .init(secret: true, fileFormat: clipboard.fileFormat)],
                    security: .strict, created: date, updated: date)
                do { try metaStore.save(metadata) }
                catch { throw ClipboardSaveError.metadataCommitFailed }
            }
            // Restore keeps original metadata/grants byte-for-byte. Verify in-process, never return the value.
            guard try service.retrieve(credentialId: request.credentialId, fieldName: request.fieldName) == value else {
                throw ClipboardSaveError.storageUnavailable
            }
            clipboard.clearIfUnchanged(since: countAtRead)
            finish(.init(success: true, shape: shape))
            NotificationCenter.default.post(name: .clipboardCredentialSaved, object: nil)
        } catch {
            finish(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable,
                         shape: shapeOnFailure))
        }
    }

    private func validateTarget(_ request: ClipboardSaveRequest, metadata: MetaFile,
                                fileFormat: CredentialFileFormat?) throws {
        guard metadata.version == 1 else { throw ClipboardSaveError.storageUnavailable }
        // 【独立审计 2026-09-13】the field name comes straight from the agent's request. Refused
        // before any prompt: nobody should be asked to approve a name that would steer `run`.
        if request.create, EnvironmentVariableName.isReserved(fieldName: request.fieldName) {
            throw ClipboardSaveError.reservedFieldName
        }
        if request.create {
            guard metadata.credentials[request.credentialId] == nil else { throw ClipboardSaveError.valueExists }
            let directory = metaStore.fileURL.deletingLastPathComponent()
            guard try GrantStore(directory: directory).grants(for: request.credentialId).isEmpty,
                  try ServiceGrantStore(directory: directory).grants(credentialId: request.credentialId).isEmpty else {
                throw ClipboardSaveError.staleGrants
            }
        } else {
            guard metadata.credentials[request.credentialId]?.fields[request.fieldName]?.secret == true else {
                throw ClipboardSaveError.targetNotFound
            }
            guard metadata.credentials[request.credentialId]?.fields[request.fieldName]?.fileFormat == fileFormat else {
                throw ClipboardSaveError.wrongFieldType
            }
        }
        let inventory = try service.fieldNamesByCredential()
        if request.isReplacement {
            guard fileFormat == nil, inventory[request.credentialId]?.contains(request.fieldName) == true else {
                throw ClipboardSaveError.targetNotFound
            }
            return
        }
        // Also protect orphan values left by a failed metadata commit.
        if request.create, inventory[request.credentialId] != nil { throw ClipboardSaveError.valueExists }
        guard inventory[request.credentialId]?.contains(request.fieldName) != true else {
            throw ClipboardSaveError.valueExists
        }
    }

    private func canonical(_ metadata: MetaFile) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    private func finish(_ response: ClipboardSaveResponse) {
        guard let pending else { return }
        self.pending = nil; isPresented = false; timer?.invalidate(); timer = nil
        dismiss()
        pending.completion(response)
    }
}

extension Notification.Name {
    static let clipboardCredentialSaved = Notification.Name("KeyKeeper.clipboardCredentialSaved")
}

/// Shown through the shared trust prompt: no text input and no secret preview.
/// Esc cancels, ⌘↩ saves, plain Return does nothing.
@MainActor private final class ClipboardSaveWindow {
    private let presenter = TrustPromptPresenter()

    func show(_ info: ClipboardSaveController.Presentation, decide: @escaping (Bool) -> Void) {
        let symbol = info.pythonSymbol != nil ? "chevron.left.forwardslash.chevron.right"
            : info.filePath != nil ? "doc.badge.gearshape"
            : info.fromBrowser ? "safari" : "doc.on.clipboard"
        presenter.show(.save(info), symbol: symbol, decide: decide)
    }

    func dismiss() { presenter.dismiss() }
}
