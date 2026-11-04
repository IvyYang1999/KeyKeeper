import Foundation

/// One cycle owns the native operation until its callback ends, even after disable/cancel.
/// Transport creation is lazy; default-off load never reaches iCloud or reads credential values.
public actor CloudSyncCoordinator {
    private struct Review {
        let id: UUID
        let local: CloudSyncLocalCapture
        let remote: CloudSyncRemote?
        let strict: Bool
    }
    private let local: any CloudSyncLocalStore
    private let stateStore: any CloudSyncStateStoring
    private let makeTransport: @Sendable () throws -> any CloudSyncTransport
    private var transport: (any CloudSyncTransport)?
    private var state = CloudSyncStoredState()
    private var loaded = false
    private var runEpoch: UInt64 = 0
    private var inFlight = false
    private var blocked: CloudSyncError?
    private var stoppedUntilEnable = false
    private var review: Review?
    private var missingCounts: (credentials: Int, fields: Int)?
    public private(set) var status = CloudSyncStatus()

    public init(local: any CloudSyncLocalStore, stateStore: any CloudSyncStateStoring,
                makeTransport: @escaping @Sendable () throws -> any CloudSyncTransport) {
        self.local = local; self.stateStore = stateStore; self.makeTransport = makeTransport
    }

    public func load() {
        guard !inFlight else { return }
        do {
            state = try stateStore.load() ?? CloudSyncStoredState()
            missingCounts = nil
            loaded = true
            blocked = state.accountChangePaused ? .accountChanged : (stoppedUntilEnable && state.enabled ? .stateUnavailable : nil)
            show(state.enabled ? (blocked == nil ? .ready : .paused) : .off, error: blocked)
        } catch { loaded = false; blocked = .stateUnavailable; show(.paused, error: .stateUnavailable) }
    }

    public func enable() async {
        guard ensureLoaded(), let token = begin() else { return }
        defer { end() }
        do {
            // Require verified, readable local data before any network operation.
            _ = try captureLocal()
            transport = try makeTransport()
            let binding = try await transport!.binding()
            try binding.validate()
            try active(token)
            guard state.binding == nil || state.binding == binding else { throw CloudSyncError.accountChanged }
            try fenced(token, binding) {
                var next = state; next.enabled = true; next.binding = binding; next.accountChangePaused = false
                try persist(next); blocked = nil; stoppedUntilEnable = false
            }
            try await cycle(token, binding)
        } catch { fail(error, token: token) }
    }

    public func disable() {
        stoppedUntilEnable = true
        runEpoch &+= 1
        blocked = .unavailable
        transport?.cancel()
        review = nil
        guard ensureLoaded() else { return }
        do {
            var next = state; next.enabled = false
            try persist(next)
            blocked = nil
            show(.off)
        } catch { show(.paused, error: .stateUnavailable) }
    }

    public func accountChanged() {
        stoppedUntilEnable = true
        runEpoch &+= 1
        blocked = .accountChanged
        transport?.cancel()
        review = nil
        guard loaded else { show(.paused, error: .accountChanged); return }
        do {
            var next = state; next.accountChangePaused = true
            try persist(next)
            show(state.enabled ? .paused : .off, error: state.enabled ? .accountChanged : nil)
        } catch { show(.paused, error: .stateUnavailable) }
    }

    public func syncNow() async {
        guard !stoppedUntilEnable, ensureLoaded(), state.enabled, blocked == nil, let token = begin() else { return }
        defer { end() }
        do {
            if transport == nil { transport = try makeTransport() }
            let binding = try await checkedBinding(token)
            try await cycle(token, binding)
        } catch { fail(error, token: token) }
    }

    public func resolve(reviewID: UUID, choices: [String: CloudSyncChoice]) async {
        guard !stoppedUntilEnable, ensureLoaded(), state.enabled, blocked == nil, let selected = review,
              selected.id == reviewID, let token = begin() else { return }
        defer { end() }
        do {
            let binding = try await checkedBinding(token)
            let remote = try await transport!.fetch(binding: binding)
            try active(token)
            guard try sameRemote(remote, selected.remote) else { throw CloudSyncError.localChanged }
            let captured = try captureLocal()
            guard captured.revision == selected.local.revision else { throw CloudSyncError.localChanged }
            let empty = try CloudVaultSnapshot(credentials: [:])
            let desired = try CloudVaultMerge.resolve(base: try base(), local: captured.snapshot,
                remote: remote?.snapshot ?? empty, choices: choices, strict: selected.strict)
            try await applyAndPublish(desired, captured: captured, remote: remote, binding: binding,
                                      token: token, forceUpload: state.pending != nil)
        } catch { fail(error, token: token) }
    }

    /// Explicit retry after a fresh conditional-head check. If the user deleted the
    /// last local item before any head was established, publish that current empty
    /// state instead of replaying an obsolete candidate containing deleted secrets.
    public func retryPendingUpload() async {
        guard !stoppedUntilEnable, ensureLoaded(), state.enabled, blocked == nil, state.pending != nil,
              let token = begin() else { return }
        defer { end() }
        do {
            let binding = try await checkedBinding(token)
            try fenced(token, binding) { try recoverTransition() }
            let remote = try await transport!.fetch(binding: binding)
            try active(token)
            guard let pending = state.pending else { return }
            guard remote != nil || pending.expectedRevisionID == nil && state.baseData == nil else {
                throw CloudSyncError.unavailable
            }
            if try matches(remote, pending) { try confirm(pending, token: token, binding: binding); return }
            let captured = try captureLocal()
            if try confirmConvergence(remote, captured: captured, pending: pending, token: token, binding: binding) { return }
            if isUnestablishedEmptyHead(remote, captured: captured, pending: pending) {
                if try captured.snapshot.encoded() == pending.snapshotData {
                    // Reuse an already durable empty publication's identity/root.
                    try fenced(token, binding) { _ = try applyLocal(captured.snapshot, expectedRevision: captured.revision) }
                    try await publish(pending, binding: binding, token: token)
                } else {
                    try await applyAndPublish(captured.snapshot, captured: captured, remote: nil,
                        binding: binding, token: token, forceUpload: true)
                }
                return
            }
            guard expectedHead(remote, pending), try captured.snapshot.encoded() == pending.snapshotData else {
                try presentReview(captured, remote: remote, strict: true); return
            }
            try await publish(pending, binding: binding, token: token)
        } catch { fail(error, token: token) }
    }

    private func cycle(_ token: UInt64, _ binding: CloudSyncBinding) async throws {
        try fenced(token, binding) { try recoverTransition() }
        let remote = try await transport!.fetch(binding: binding)
        try active(token)
        try validate(remote)
        if let pending = state.pending {
            guard remote != nil || pending.expectedRevisionID == nil && state.baseData == nil else {
                throw CloudSyncError.unavailable
            }
            if try matches(remote, pending) { try confirm(pending, token: token, binding: binding); return }
            let captured = try captureLocal()
            if try confirmConvergence(remote, captured: captured, pending: pending, token: token, binding: binding) { return }
            if try isUnestablishedEmptyHead(remote, captured: captured, pending: pending)
                || expectedHead(remote, pending) && captured.snapshot.encoded() == pending.snapshotData {
                review = nil
                show(.paused, error: .pendingUpload); status.canRetryPendingUpload = true
            } else { try presentReview(captured, remote: remote, strict: true) }
            return // Recovery of uncertain writes is read-only; never replay on a timer.
        }
        guard remote != nil || state.baseData == nil else { throw CloudSyncError.unavailable }
        let captured = try captureLocal()
        let empty = try CloudVaultSnapshot(credentials: [:])
        let merged = try CloudVaultMerge.merge(base: try base(), local: captured.snapshot, remote: remote?.snapshot ?? empty)
        if !merged.conflictingIDs.isEmpty { try presentReview(captured, remote: remote, strict: false); return }
        try await applyAndPublish(merged.resolved(), captured: captured, remote: remote,
                                  binding: binding, token: token, forceUpload: false)
    }

    private func applyAndPublish(_ desired: CloudVaultSnapshot, captured: CloudSyncLocalCapture,
                                 remote: CloudSyncRemote?, binding: CloudSyncBinding,
                                 token: UInt64, forceUpload: Bool) async throws {
        let desiredData = try desired.encoded(), remoteData = try remote?.snapshot.encoded()
        let upload = desiredData != remoteData || forceUpload ? CloudSyncPendingUpload(id: UUID(),
            snapshotData: desiredData, expectedRevisionID: remote?.revisionID, expectedChangeToken: remote?.changeToken) : nil
        let transition = try CloudSyncLocalTransition(beforeData: captured.snapshot.encoded(),
            desiredData: desiredData, remoteData: remoteData, upload: upload)
        try fenced(token, binding) {
            var next = state; next.transition = transition
            try persist(next)
            _ = try applyLocal(desired, expectedRevision: captured.revision)
            try finishTransition(transition)
        }
        review = nil
        if let upload { try await publish(upload, binding: binding, token: token) }
        else { show(.synced) }
    }

    private func recoverTransition() throws {
        guard let transition = state.transition else { return }
        let current = try captureLocal(), bytes = try current.snapshot.encoded()
        if bytes == transition.beforeData {
            _ = try applyLocal(CloudVaultSnapshot.decode(transition.desiredData), expectedRevision: current.revision)
        } else if bytes != transition.desiredData { throw CloudSyncError.stateUnavailable }
        try finishTransition(transition)
    }

    private func finishTransition(_ transition: CloudSyncLocalTransition) throws {
        var next = state
        next.baseData = transition.remoteData
        next.pending = transition.upload
        next.transition = nil
        if transition.upload == nil { next.lastSuccess = Date() }
        try persist(next)
    }

    private func publish(_ pending: CloudSyncPendingUpload, binding: CloudSyncBinding, token: UInt64) async throws {
        try active(token)
        try await transport!.upload(pending, binding: binding)
        try active(token)
        let remote = try await transport!.fetch(binding: binding)
        try active(token)
        if try matches(remote, pending) { try confirm(pending, token: token, binding: binding); return }
        let captured = try captureLocal()
        guard try confirmConvergence(remote, captured: captured, pending: pending, token: token, binding: binding) else {
            throw CloudSyncError.pendingUpload
        }
    }

    /// Another Mac may publish the same content under its own revision. A fresh head
    /// and unchanged local capture can acknowledge that convergence without replaying
    /// our old candidate or inventing a conflict that has no differences to resolve.
    private func confirmConvergence(_ remote: CloudSyncRemote?, captured: CloudSyncLocalCapture,
                                    pending: CloudSyncPendingUpload, token: UInt64,
                                    binding: CloudSyncBinding) throws -> Bool {
        try validate(remote)
        guard let remote, try captured.snapshot.encoded() == remote.snapshot.encoded() else { return false }
        try fenced(token, binding) {
            guard state.pending == pending else { throw CloudSyncError.stateUnavailable }
            // This is a no-op apply, but its original revision check closes the gap
            // between capture and acknowledgement. A later local edit stays pending.
            _ = try applyLocal(captured.snapshot, expectedRevision: captured.revision)
            var next = state; next.baseData = try remote.snapshot.encoded(); next.pending = nil; next.lastSuccess = Date()
            try persist(next)
        }
        review = nil; show(.synced)
        return true
    }

    private func isUnestablishedEmptyHead(_ remote: CloudSyncRemote?, captured: CloudSyncLocalCapture,
                                         pending: CloudSyncPendingUpload) -> Bool {
        remote == nil && state.baseData == nil && pending.expectedRevisionID == nil
            && pending.expectedChangeToken == nil && captured.snapshot.credentials.isEmpty
    }

    private func confirm(_ pending: CloudSyncPendingUpload, token: UInt64, binding: CloudSyncBinding) throws {
        try fenced(token, binding) {
            guard state.pending == pending else { throw CloudSyncError.stateUnavailable }
            var next = state; next.baseData = pending.snapshotData; next.pending = nil; next.lastSuccess = Date()
            try persist(next)
        }
        review = nil; show(.synced)
    }

    private func presentReview(_ captured: CloudSyncLocalCapture, remote: CloudSyncRemote?, strict: Bool) throws {
        let other = try remote?.snapshot ?? CloudVaultSnapshot(credentials: [:])
        let ids = strict ? try CloudVaultMerge.divergentIDs(local: captured.snapshot, remote: other)
            : try CloudVaultMerge.merge(base: base(), local: captured.snapshot, remote: other).conflictingIDs
        // Equal content has no meaningful choices. Callers handle established
        // convergence or actionable initial-head uncertainty before reaching here.
        guard !ids.isEmpty else { review = nil; throw CloudSyncError.pendingUpload }
        let reviewID: UUID
        if let review, review.local.revision == captured.revision, review.strict == strict,
           try sameRemote(review.remote, remote) { reviewID = review.id }
        else { reviewID = UUID() }
        let newReview = Review(id: reviewID, local: captured, remote: remote, strict: strict)
        review = newReview
        show(.conflicts)
        status.reviewID = newReview.id
        status.conflicts = try ids.map { id in
            .init(credentialID: id, title: captured.snapshot.credentials[id]?.metadata.label
                ?? other.credentials[id]?.metadata.label ?? id,
                localDeleted: captured.snapshot.credentials[id] == nil, remoteDeleted: other.credentials[id] == nil,
                canChooseLocal: try CloudVaultMerge.canChoose(.local, local: captured.snapshot.credentials[id], remote: other.credentials[id]),
                canChooseRemote: try CloudVaultMerge.canChoose(.remote, local: captured.snapshot.credentials[id], remote: other.credentials[id]))
        }
    }

    private func captureLocal() throws -> CloudSyncLocalCapture {
        let captured = try localOperation { try local.capture() }
        observeMissing(captured.snapshot)
        return captured
    }

    private func applyLocal(_ desired: CloudVaultSnapshot, expectedRevision: VaultRevision) throws -> [String] {
        let changed = try localOperation { try local.apply(desired, expectedRevision: expectedRevision) }
        observeMissing(desired)
        return changed
    }

    private func observeMissing(_ snapshot: CloudVaultSnapshot) {
        missingCounts = (snapshot.missingCredentialCount, snapshot.missingFieldCount)
    }

    private func localOperation<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as CloudSyncError { throw error }
        catch let error as VaultRevisionError { throw error }
        catch let error as VaultAccessError { throw error }
        catch let error as CloudVaultError { throw error }
        catch { throw CloudSyncError.localDataUnavailable }
    }

    private func checkedBinding(_ token: UInt64) async throws -> CloudSyncBinding {
        guard let transport, let expected = state.binding else { throw CloudSyncError.setupRequired }
        let current = try await transport.binding()
        try active(token); try current.validate()
        guard current == expected else { throw CloudSyncError.accountChanged }
        return current
    }
    private func base() throws -> CloudVaultSnapshot? { try state.baseData.map(CloudVaultSnapshot.decode) }
    private func validate(_ remote: CloudSyncRemote?) throws {
        if let remote {
            _ = try remote.snapshot.encoded()
            guard !remote.changeToken.isEmpty, remote.changeToken.count <= 1024 * 1024 else { throw CloudSyncError.unavailable }
        }
    }
    private func sameRemote(_ a: CloudSyncRemote?, _ b: CloudSyncRemote?) throws -> Bool {
        guard a?.revisionID == b?.revisionID, a?.changeToken == b?.changeToken else { return false }
        return try a?.snapshot.encoded() == b?.snapshot.encoded()
    }
    private func expectedHead(_ remote: CloudSyncRemote?, _ pending: CloudSyncPendingUpload) -> Bool {
        remote?.revisionID == pending.expectedRevisionID && remote?.changeToken == pending.expectedChangeToken
    }
    private func matches(_ remote: CloudSyncRemote?, _ pending: CloudSyncPendingUpload) throws -> Bool {
        guard let remote, remote.revisionID == pending.id else { return false }
        return try remote.snapshot.encoded() == pending.snapshotData
    }
    private func persist(_ next: CloudSyncStoredState) throws {
        do { try stateStore.save(next); state = next }
        catch { loaded = false; blocked = .stateUnavailable; throw CloudSyncError.stateUnavailable }
    }
    private func fenced<T>(_ token: UInt64, _ binding: CloudSyncBinding, _ effect: () throws -> T) throws -> T {
        guard let transport else { throw CloudSyncError.unavailable }
        return try transport.withCurrentBinding(binding) { try active(token); return try effect() }
    }
    private func active(_ token: UInt64) throws {
        guard token == runEpoch else { throw CloudSyncError.unavailable }
    }
    private func ensureLoaded() -> Bool { if !loaded { load() }; return loaded }
    private func begin() -> UInt64? {
        guard !inFlight, transport?.hasOutstandingOperation != true else { status.busy = true; return nil }
        inFlight = true; show(.syncing); return runEpoch
    }
    private func end() { inFlight = false; status.busy = transport?.hasOutstandingOperation == true }
    private func show(_ phase: CloudSyncPhase, error: CloudSyncError? = nil) {
        status = .init(enabled: state.enabled, phase: phase, lastSuccess: state.lastSuccess,
                       error: error, busy: inFlight || transport?.hasOutstandingOperation == true,
                       missingCredentialCount: phase == .off ? nil : missingCounts?.credentials,
                       missingFieldCount: phase == .off ? nil : missingCounts?.fields)
    }
    private func fail(_ error: Error, token: UInt64) {
        guard token == runEpoch else { return }
        let safe: CloudSyncError
        if let known = error as? CloudSyncError { safe = known }
        else if let vault = error as? CloudVaultError {
            switch vault {
            case .unsupportedVersion: safe = .unsupportedSnapshotVersion
            case .conflictingChanges: safe = .conflict
            default: safe = .localDataUnavailable
            }
        }
        else if error is VaultRevisionError || error is VaultAccessError { safe = .localChanged }
        else { safe = .unavailable }
        if safe == .accountChanged { accountChanged(); return }
        show(.paused, error: safe)
    }
}
