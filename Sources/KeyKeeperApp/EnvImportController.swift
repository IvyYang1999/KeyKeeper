import AppKit
import KeyKeeperCore

/// `keykeeper import <.env>`: one credential, one field per variable. The App reads the file
/// itself, shows the variable names for approval, and writes the values straight into the
/// Keychain. The caller learns names and counts, never a value.
@MainActor final class EnvImportController {
    struct Presentation {
        let request: EnvImportRequest
        let callerName: String
        let plan: EnvImportPlan
        let expiresAt: Date
    }
    private struct Pending {
        let id: UUID
        let presentation: Presentation
        let metadata: Data
        let source: CredentialFileSource
        let isConnected: () -> Bool
        let completion: (ClipboardSaveResponse) -> Void
    }

    private let service: KeychainCredentialService
    private let metaStore: MetaStore
    private let approvals: ApprovalStore
    private let now: () -> Date
    private let present: (Presentation, @escaping (Bool) -> Void) -> Void
    private let dismiss: () -> Void
    private var pending: Pending?
    private var timer: Timer?
    var isPending: Bool { pending != nil }

    init(service: KeychainCredentialService, metaStore: MetaStore = .default, approvals: ApprovalStore,
         now: @escaping () -> Date = Date.init,
         present: ((Presentation, @escaping (Bool) -> Void) -> Void)? = nil,
         dismiss: (() -> Void)? = nil) {
        self.service = service; self.metaStore = metaStore; self.approvals = approvals; self.now = now
        let window = EnvImportWindow()
        self.present = present ?? { info, decide in
            if TestInstance.autoApprove != nil { DispatchQueue.main.async { decide(true) } } else { window.show(info, decide: decide) }
        }
        self.dismiss = dismiss ?? { window.dismiss() }
    }

    func receive(_ request: EnvImportRequest, callerName: String,
                 isConnected: @escaping () -> Bool,
                 completion: @escaping (ClipboardSaveResponse) -> Void) {
        guard pending == nil else { completion(.init(success: false, errorCode: .busy)); return }
        do {
            try request.validate()
            guard isConnected() else { throw ClipboardSaveError.disconnected }
            let metadata = try metaStore.load()
            try validateTarget(request, metadata: metadata)
            let source = try CredentialFileSource(envFilePath: request.filePath)
            // Names are read now so the person can see what they are approving; the values are
            // parsed along with them but stay in this process and are read again on approval.
            let plan = try Self.plan(from: source)
            guard !plan.isEmpty else { throw ClipboardSaveError.emptyEnvFile }
            let expiresAt = now().addingTimeInterval(90)
            let info = Presentation(request: request, callerName: callerName, plan: plan, expiresAt: expiresAt)
            let id = UUID()
            pending = Pending(id: id, presentation: info, metadata: try canonical(metadata), source: source,
                              isConnected: isConnected, completion: completion)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.expireIfNeeded() }
            }
            present(info) { [weak self] approved in
                guard self?.pending?.id == id else { return }
                self?.resolve(approved: approved)
            }
        } catch {
            completion(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable))
        }
    }

    func cancel() { if pending != nil { finish(.init(success: false, errorCode: .denied)) } }

    func expireIfNeeded() {
        guard let pending else { return }
        if now() >= pending.presentation.expiresAt { finish(.init(success: false, errorCode: .expired)) }
        else if !pending.isConnected() { finish(.init(success: false, errorCode: .disconnected)) }
    }

    func resolve(approved: Bool) {
        expireIfNeeded()
        guard let pending else { return }
        guard approved else { cancel(); return }
        var written: [String] = []
        do {
            let request = pending.presentation.request
            var metadata = try metaStore.load()
            guard try canonical(metadata) == pending.metadata else { throw ClipboardSaveError.metadataChanged }
            try validateTarget(request, metadata: metadata)
            guard now() < pending.presentation.expiresAt else { throw ClipboardSaveError.expired }
            guard pending.isConnected() else { throw ClipboardSaveError.disconnected }
            // The file must still be the one the person looked at: same identity, same names.
            let entries = try Self.entries(from: pending.source)
            let plan = EnvImportPlan.make(entries)
            guard plan == pending.presentation.plan else { throw ClipboardSaveError.fileChanged }
            let values = Dictionary(entries.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last })
            var fields: [String: CredentialField] = [:]
            for field in plan.fields {
                guard let value = values[field.name] else { throw ClipboardSaveError.fileChanged }
                if field.secret {
                    try service.saveMissing(credentialId: request.credentialId, fieldName: field.fieldName, value: value)
                    written.append(field.fieldName)
                    fields[field.fieldName] = CredentialField(secret: true, displayName: field.name)
                } else {
                    fields[field.fieldName] = CredentialField(value: value, secret: false, displayName: field.name)
                }
            }
            let date = ISO8601DateFormatter().string(from: now())
            metadata.credentials[request.credentialId] = Credential(
                label: request.label ?? request.credentialId, notes: "", links: [], fields: fields,
                security: request.security ?? .strict, created: date, updated: date,
                intent: request.intent?.sanitized().map { intent in
                    var declared = intent
                    declared.declaredBy = pending.presentation.callerName
                    declared.declaredAt = now()
                    return declared
                },
                // Imported over the socket, i.e. by an agent: never handed back to one.
                injectOnly: true)
            do { try metaStore.save(metadata) } catch { throw ClipboardSaveError.metadataCommitFailed }
            for field in plan.fields where field.secret {
                guard try service.retrieve(credentialId: request.credentialId, fieldName: field.fieldName) == values[field.name] else {
                    throw ClipboardSaveError.storageUnavailable
                }
            }
            NotificationCenter.default.post(name: .clipboardCredentialSaved, object: nil)
            let secrets = plan.secretNames.count, plain = plan.plainNames.count
            finish(.init(success: true, detail: "\(secrets) secret, \(plain) plain, \(plan.skipped.count) skipped"))
        } catch {
            // A half-written credential must not survive as orphan values under this id.
            if (error as? ClipboardSaveError) != .metadataCommitFailed {
                for field in written { try? service.delete(credentialId: pending.presentation.request.credentialId, fieldName: field) }
            }
            finish(.init(success: false, errorCode: error as? ClipboardSaveError ?? .storageUnavailable))
        }
    }

    static func entries(from source: CredentialFileSource) throws -> [EnvEntry] {
        guard let text = try source.readText() else { throw ClipboardSaveError.invalidEnvFile }
        return EnvFileParser.parse(text)
    }
    static func plan(from source: CredentialFileSource) throws -> EnvImportPlan {
        EnvImportPlan.make(try entries(from: source))
    }

    private func validateTarget(_ request: EnvImportRequest, metadata: MetaFile) throws {
        guard metadata.version == 1 else { throw ClipboardSaveError.storageUnavailable }
        guard metadata.credentials[request.credentialId] == nil else { throw ClipboardSaveError.credentialExists }
        guard try !approvals.hasApprovals(forCredential: request.credentialId) else { throw ClipboardSaveError.staleGrants }
        // Orphan values from an earlier failed commit are not silently adopted either.
        guard try service.fieldNamesByCredential()[request.credentialId] == nil else { throw ClipboardSaveError.credentialExists }
    }

    private func canonical(_ metadata: MetaFile) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(metadata)
    }

    private func finish(_ response: ClipboardSaveResponse) {
        guard let pending else { return }
        self.pending = nil; timer?.invalidate(); timer = nil
        dismiss()
        pending.completion(response)
    }
}

@MainActor private final class EnvImportWindow {
    private let presenter = TrustPromptPresenter()
    func show(_ info: EnvImportController.Presentation, decide: @escaping (Bool) -> Void) {
        presenter.show(.envImport(info), symbol: "doc.text.magnifyingglass", decide: decide)
    }
    func dismiss() { presenter.dismiss() }
}

extension TrustPromptModel {
    /// Variable names are the whole story here: the person is approving *which* facts move
    /// into the Keychain, and can see at a glance if the agent pointed at the wrong file.
    static func envImport(_ info: EnvImportController.Presentation) -> TrustPromptModel {
        let caller = sanitizedCaller(info.callerName)
        let path = info.request.filePath
        let plan = info.plan
        var rows = [
            Row(label: L("Save as"), value: info.request.credentialId, monospaced: true,
                note: L("New, \(plan.fields.count) fields") + " · " + ((info.request.security ?? .strict) == .strict ? L("Ask every time") : L("Background OK"))),
            Row(label: L("Source"), value: (path as NSString).lastPathComponent, monospaced: true, help: path),
            Row(label: L("Requested by"), value: caller, icon: .caller(info.callerName)),
        ]
        if !plan.secretNames.isEmpty {
            rows.append(Row(label: L("Secrets"), value: plan.secretNames.joined(separator: "  "), monospaced: true,
                            note: L("Into the Keychain; only ever injected by keykeeper run.")))
        }
        if !plan.plainNames.isEmpty {
            rows.append(Row(label: L("Plain"), value: plan.plainNames.joined(separator: "  "), monospaced: true,
                            note: L("Kept as readable settings next to the keys.")))
        }
        if !plan.skipped.isEmpty {
            rows.append(Row(label: L("Skipped"), value: plan.skipped.map(\.name).joined(separator: "  "), monospaced: true,
                            note: L("Empty, reserved, or a name that cannot become a field.")))
        }
        return TrustPromptModel(
            title: L("Move this .env into KeyKeeper?"),
            subtitle: L("\(caller) wants its secrets out of the plaintext file"),
            rows: rows,
            assurance: L("\(caller) never sees the values. The file is left where it is; delete it yourself once everything runs."),
            tone: .reassuring,
            details: [
                L("The names above were read to show this list; the values go from the file straight into the Keychain when you approve, and are never displayed. If the file changes meanwhile, the import is refused. This request expires in 90 seconds."),
                L("These values have been sitting in a plaintext file. Rotate them at their providers when you can — moving them protects the future, not the past."),
            ],
            confirmTitle: L("Import"), expiresAt: info.expiresAt)
    }
}
