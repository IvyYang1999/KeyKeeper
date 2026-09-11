import AppKit
import KeyKeeperCore

@MainActor protocol ClipboardSaveSource: AnyObject {
    var changeCount: Int { get }
    var fileFormat: CredentialFileFormat? { get }
    var displayFilePath: String? { get }
    var pythonSymbol: String? { get }
    func readText() throws -> String?
    func clearIfUnchanged(since count: Int)
}

extension ClipboardSaveSource {
    var fileFormat: CredentialFileFormat? { nil }
    var displayFilePath: String? { nil }
    var pythonSymbol: String? { nil }
}

@MainActor final class SystemClipboardSaveSource: ClipboardSaveSource {
    var changeCount: Int { NSPasteboard.general.changeCount }
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
                changeCount: source.changeCount, source: source, expiresAt: expiresAt,
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
        do {
            let clipboard = pending.source
            let request = pending.presentation.request
            var metadata = try metaStore.load()
            guard try canonical(metadata) == pending.metadata else { throw ClipboardSaveError.metadataChanged }
            try validateTarget(request, metadata: metadata, fileFormat: clipboard.fileFormat)
            let changed: ClipboardSaveError = clipboard.displayFilePath == nil ? .clipboardChanged : .fileChanged
            guard clipboard.changeCount == pending.changeCount else { throw changed }
            // No pasteboard string is fetched until the target and one-time approval are validated.
            guard let value = try clipboard.readText(), value.utf8.count <= 65_536,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ClipboardSaveError.emptyClipboard
            }
            guard clipboard.changeCount == pending.changeCount else { throw changed }
            guard now() < pending.expiresAt else { throw ClipboardSaveError.expired }
            guard pending.isConnected() else { throw ClipboardSaveError.disconnected }
            try service.saveMissing(credentialId: request.credentialId, fieldName: request.fieldName, value: value)
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
            clipboard.clearIfUnchanged(since: pending.changeCount)
            finish(.init(success: true))
            NotificationCenter.default.post(name: .clipboardCredentialSaved, object: nil)
        } catch {
            finish(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable))
        }
    }

    private func validateTarget(_ request: ClipboardSaveRequest, metadata: MetaFile,
                                fileFormat: CredentialFileFormat?) throws {
        guard metadata.version == 1 else { throw ClipboardSaveError.storageUnavailable }
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
