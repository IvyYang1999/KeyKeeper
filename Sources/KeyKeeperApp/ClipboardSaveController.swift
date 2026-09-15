import AppKit
import KeyKeeperCore
import CryptoKit

@MainActor protocol ClipboardSaveSource: AnyObject {
    var changeCount: Int { get }
    /// True for the shared system clipboard: whatever is there when the person approves is what
    /// is saved, and the confirmation shows a preview of it that follows the clipboard. The
    /// browser and file sources own their content and must not change under the prompt.
    var isSystemClipboard: Bool { get }
    var fileFormat: CredentialFileFormat? { get }
    var displayFilePath: String? { get }
    var pythonSymbol: String? { get }
    func readText() throws -> String?
    func clearIfUnchanged(since count: Int)
    /// A masked look at the current content for the confirmation, or nil when there is nothing to show.
    func preview() -> ClipboardPreview?
}

extension ClipboardSaveSource {
    var isSystemClipboard: Bool { false }
    var fileFormat: CredentialFileFormat? { nil }
    var displayFilePath: String? { nil }
    var pythonSymbol: String? { nil }
    func preview() -> ClipboardPreview? { nil }
}

@MainActor final class SystemClipboardSaveSource: ClipboardSaveSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var isSystemClipboard: Bool { true }
    func readText() -> String? { NSPasteboard.general.string(forType: .string) }
    func clearIfUnchanged(since count: Int) { SecretPasteboard.clearIfUnchanged(since: count) }
    func preview() -> ClipboardPreview? {
        guard let text = readText(), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var preview = ClipboardPreview.masked(text)
        preview.copiedAt = ClipboardWatch.shared.lastChangeAt
        return preview
    }
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
        /// What the clipboard looks like right now; refreshed while the prompt is up.
        var preview: ClipboardPreview?
    }
    private struct Pending {
        let id: UUID
        var presentation: Presentation
        let metadata: Data
        var changeCount: Int
        let valueFingerprint: Data?
        let source: ClipboardSaveSource
        let expiresAt: Date
        let isConnected: () -> Bool
        let completion: (ClipboardSaveResponse) -> Void
    }
    private let service: KeychainCredentialService
    private let metaStore: MetaStore
    private let approvals: ApprovalStore
    private let clipboard: ClipboardSaveSource
    private let now: () -> Date
    /// KeyKeeper's own check of a saved key against its provider (see ProviderProbe). Injected
    /// so tests never touch the network. The value is in the app's memory for the probe only.
    private let probe: @Sendable (ProviderValidation, String) async -> CredentialValidation
    /// True while the probe runs: the request is done as far as the person is concerned, but the
    /// caller has not been answered yet; the 90 s deadline must not fire in between.
    private var validating = false
    private let present: (Presentation, @escaping (Bool) -> Void) -> Void
    /// The prompt is already up; only its rows changed (the clipboard moved).
    private let update: (Presentation) -> Void
    private let dismiss: () -> Void
    private var pending: Pending?
    private var timer: Timer?
    private var isPresented = false
    var isPending: Bool { pending != nil }

    init(service: KeychainCredentialService, metaStore: MetaStore = .default, approvals: ApprovalStore,
         clipboard: ClipboardSaveSource? = nil, now: @escaping () -> Date = Date.init,
         present: ((Presentation, @escaping (Bool) -> Void) -> Void)? = nil,
         update: ((Presentation) -> Void)? = nil,
         dismiss: (() -> Void)? = nil,
         probe: (@Sendable (ProviderValidation, String) async -> CredentialValidation)? = nil) {
        self.service = service; self.metaStore = metaStore; self.approvals = approvals
        self.clipboard = clipboard ?? SystemClipboardSaveSource(); self.now = now
        self.probe = probe ?? { validation, value in await ProviderProbe.run(validation, value: value, transport: URLSessionProbeTransport()) }
        let window = ClipboardSaveWindow()
        self.present = present ?? { info, decide in
            // An isolated e2e instance answers itself; the prompt never appears.
            if TestInstance.autoApprove != nil { DispatchQueue.main.async { decide(true) } } else { window.show(info, decide: decide) }
        }
        self.update = update ?? { info in window.update(info) }
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
            let source = source ?? clipboard
            let info = Presentation(request: request, callerName: callerName,
                fromBrowser: source.displayFilePath == nil && !source.isSystemClipboard,
                filePath: source.displayFilePath, pythonSymbol: source.pythonSymbol,
                expiresAt: expiresAt, preview: source.isSystemClipboard ? source.preview() : nil)
            let id = UUID()
            pending = Pending(id: id, presentation: info, metadata: try canonical(metadata),
                changeCount: source.changeCount,
                valueFingerprint: request.isReplacement ? try service.valueFingerprint(
                    credentialId: request.credentialId, fieldName: request.fieldName) : nil,
                source: source, expiresAt: expiresAt,
                isConnected: isConnected, completion: completion)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
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

    /// Once a second while a save is pending: expire, or follow the clipboard so the prompt
    /// always shows what approving would store.
    func tick() {
        expireIfNeeded()
        guard let pending, pending.source.isSystemClipboard, pending.source.changeCount != pending.changeCount else { return }
        self.pending?.changeCount = pending.source.changeCount
        self.pending?.presentation.preview = pending.source.preview()
        if isPresented, let presentation = self.pending?.presentation { update(presentation) }
    }

    func expireIfNeeded() {
        guard let pending, !validating else { return }
        if now() >= pending.expiresAt { finish(.init(success: false, errorCode: .expired)) }
        else if !pending.isConnected() { finish(.init(success: false, errorCode: .disconnected)) }
    }

    func cancel() { if pending != nil { finish(.init(success: false, errorCode: .denied)) } }

    func resolve(approved: Bool) {
        expireIfNeeded()
        guard let pending, isPresented, !validating else { return }
        guard approved else { cancel(); return }
        // Reported only when a declared shape did not match: the caller needs to know what it
        // nearly stored. Every other failure says nothing about the clipboard.
        var shapeOnFailure: ValueShape?
        var refusalDetail: String?
        do {
            let clipboard = pending.source
            let request = pending.presentation.request
            var metadata = try metaStore.load()
            guard try canonical(metadata) == pending.metadata else { throw ClipboardSaveError.metadataChanged }
            try validateTarget(request, metadata: metadata, fileFormat: clipboard.fileFormat)
            let changed: ClipboardSaveError = clipboard.displayFilePath == nil ? .clipboardChanged : .fileChanged
            // Only what the person saw gets saved. The prompt follows the system clipboard once a
            // second (see tick); if it moved after the last look — 【独立审计 2026-09-14】a swap in
            // the sub-second gap before the click — refresh the preview, re-arm the settle delay,
            // and let the person look again. The request stays pending; nothing is written.
            // A file or browser source must not have changed at all.
            if clipboard.isSystemClipboard {
                if clipboard.changeCount != pending.changeCount { tick(); return }
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
            // The provider's key shape, when the caller named one: refused before a byte is written.
            let template = request.provider.flatMap(ProviderCatalog.find)
            if let template, let problem = template.shapeProblem(for: value, fieldName: request.fieldName) {
                shapeOnFailure = shape
                refusalDetail = problem
                throw ClipboardSaveError.shapeMismatch
            }
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
                    security: request.security ?? .strict, created: date, updated: date,
                    expires: request.expires,
                    intent: request.intent?.sanitized().map { intent in
                        var declared = intent
                        declared.declaredBy = pending.presentation.callerName
                        declared.declaredAt = now()
                        return declared
                    },
                    // Created over the socket, i.e. by an agent: never handed back to one.
                    injectOnly: true,
                    provider: template?.id)
                do { try metaStore.save(metadata) }
                catch { throw ClipboardSaveError.metadataCommitFailed }
            }
            // Restore keeps original metadata/grants byte-for-byte. Verify in-process, never return the value.
            guard try service.retrieve(credentialId: request.credentialId, fieldName: request.fieldName) == value else {
                throw ClipboardSaveError.storageUnavailable
            }
            clipboard.clearIfUnchanged(since: countAtRead)
            NotificationCenter.default.post(name: .clipboardCredentialSaved, object: nil)
            // Saved. If the provider can be asked, ask it before answering the caller: the window
            // goes away now, the answer carries the verdict, and the value never leaves this process.
            if let validation = template?.validation {
                validating = true
                isPresented = false
                dismiss()
                let probe = self.probe
                Task { @MainActor [weak self] in
                    let outcome = await probe(validation, value)
                    guard let self else { return }
                    self.validating = false
                    self.finish(.init(success: true, shape: shape, validation: outcome))
                }
            } else {
                finish(.init(success: true, shape: shape, validation: .skipped))
            }
        } catch {
            finish(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable,
                         shape: shapeOnFailure, detail: refusalDetail))
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
            // A new credential under a reused ID must not inherit what was given to the old one.
            guard try !approvals.hasApprovals(forCredential: request.credentialId) else {
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

    /// The clipboard moved while the prompt was up: same window, new rows.
    func update(_ info: ClipboardSaveController.Presentation) { presenter.update(.save(info)) }

    func dismiss() { presenter.dismiss() }
}
