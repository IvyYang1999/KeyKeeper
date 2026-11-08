import AppKit
import Combine
import Foundation
import CloudKit
import Network
import KeyKeeperCore

protocol ICloudSyncDriving: Sendable {
    var status: CloudSyncStatus { get async }
    func load() async
    func enable() async
    func disable() async
    func syncNow() async
    func accountChanged() async
    func retryPendingUpload() async
    func resolve(reviewID: UUID, choices: [String: CloudSyncChoice]) async
}
extension CloudSyncCoordinator: ICloudSyncDriving {}

/// Constructing the shared object is inert. Startup admission owns when it may be configured.
@MainActor
final class ICloudSyncRuntime: ObservableObject {
    static let shared = ICloudSyncRuntime()
    @Published private(set) var state = ICloudSyncPresentation()
    private var engine: (any ICloudSyncDriving)?
    private let center: NotificationCenter
    private let interval: UInt64
    private let debounce: UInt64
    let ownChange = SyncChangeToken()
    private var observers: [NSObjectProtocol] = []
    private var timer: Task<Void, Never>?
    private var delayedChange: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var activeID: UUID?
    private var actionEpoch: UInt64 = 0
    private var started = false
    private var stopRequested = false
    private var localChangePending = false
    private var productionConfigurationAttempted = false
    /// 30 s, 2 min, 10 min, then every 15 min for as long as the pause lasts.
    nonisolated static let defaultRetryDelays: [UInt64] = [30, 120, 600, 900].map { $0 * 1_000_000_000 }
    private let retryDelays: [UInt64]
    private var retryTask: Task<Void, Never>?
    private var retryDue: Date?
    private var retryAttempt = 0
    /// Wake and network signals are wired only for the production engine; tests call `systemResumed()`.
    private var systemSignals = false
    private var systemObservers: [NSObjectProtocol] = []
    private var pathMonitor: NWPathMonitor?
    private var networkSatisfied: Bool?

    init(engine: (any ICloudSyncDriving)? = nil, center: NotificationCenter = .default,
         interval: UInt64 = 120_000_000_000, debounce: UInt64 = 2_000_000_000,
         retryDelays: [UInt64] = ICloudSyncRuntime.defaultRetryDelays) {
        self.engine = engine; self.center = center; self.interval = interval; self.debounce = debounce
        self.retryDelays = retryDelays
    }

    func configureProduction() {
        guard engine == nil else { return }
        productionConfigurationAttempted = true
        guard StorageIdentity.runtime == .current else {
            state = .init(phase: .unavailable, issue: .identityUnavailable)
            return
        }
        do {
            let local = NotifyingSyncLocalStore(store: try LocalVaultCommitCoordinator.production(),
                                               center: center, token: ownChange)
            let service = try SecItemBlobIO.serviceName(environment: ProcessInfo.processInfo.environment)
            let directory = KeyKeeperPaths.applicationSupportDirectory
            let store = CloudSyncStateStore(io: SecItemBlobIO(service: service + ".cloud-sync-state"),
                marker: FileLocalVaultJournalMarker(url: directory.appendingPathComponent("cloud-sync-state.created")),
                namespace: LocalVaultJournal.namespace(service: service, directory: directory))
            engine = CloudSyncCoordinator(local: local, stateStore: store, makeTransport: {
                CloudKitSyncTransport(identity: try CloudSyncNativeIdentity.current())
            })
            systemSignals = true
        } catch {
            state = .init(phase: .unavailable, issue: .storageUnavailable)
        }
    }

    func start() async {
        guard !started, let engine else { return }
        started = true
        let epoch = actionEpoch
        await engine.load()
        await refresh()
        guard started, epoch == actionEpoch else { return }
        attachScheduling()
        if state.enabled, state.phase == .ready { perform(.syncNow) }
        else if state.retriesAutomatically { retryAttempt = 0; cancelAutoRetry(); retryNow() }
    }

    func perform(_ action: ICloudSyncAction) {
        if action == .retry, engine == nil, productionConfigurationAttempted {
            configureProduction()
            Task { await start() }
            return
        }
        guard started, let engine, action != .migrate else { return }
        if action == .disable {
            actionEpoch &+= 1; stopRequested = true
            cancelAutoRetry(); retryAttempt = 0
            delayedChange?.cancel(); delayedChange = nil
            localChangePending = false
            state.enabled = false
            Task { await engine.disable(); await refresh() }
            return
        }
        guard activeTask == nil else { return }
        actionEpoch &+= 1
        let epoch = actionEpoch, id = UUID(), wasEnabled = state.enabled
        activeID = id
        if action == .enable { stopRequested = false; state.enabled = true }
        cancelAutoRetry()
        state.phase = .syncing
        activeTask = Task {
            switch action {
            case .enable: await engine.enable()
            case .retry:
                // Carry on with what this Mac's record says once it can be read. Only a turn-off
                // asked for in this session turns sync off: a record that was unreadable at launch
                // looked "off" here, and retrying it used to switch the person's sync off.
                await engine.load()
                if epoch == actionEpoch {
                    if stopRequested { await engine.disable() }
                    else if await engine.status.enabled { await engine.enable() }
                }
            case .retryPendingUpload:
                if wasEnabled {
                    await engine.enable()
                    if epoch == actionEpoch { await engine.retryPendingUpload() }
                }
            case .syncNow: await engine.syncNow()
            case let .resolve(reviewID, choices):
                await engine.resolve(reviewID: reviewID, choices: choices.mapValues { $0 == .local ? .local : .remote })
            case .disable, .migrate: break
            }
            if activeID == id {
                activeTask = nil; activeID = nil
            }
            await refresh()
            if localChangePending { scheduleLocalChange() }
        }
    }

    private func refresh() async {
        guard started, let engine else { return }
        let epoch = actionEpoch
        var next = Self.presentation(await engine.status)
        guard started, epoch == actionEpoch else { return }
        if stopRequested { next.enabled = false }
        state = next
        updateAutoRetry()
    }

    func stopScheduling() {
        started = false
        actionEpoch &+= 1
        localChangePending = false
        timer?.cancel(); timer = nil
        delayedChange?.cancel(); delayedChange = nil
        cancelAutoRetry()
        observers.forEach(center.removeObserver)
        observers = []
        systemObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        systemObservers = []
        pathMonitor?.cancel(); pathMonitor = nil; networkSatisfied = nil
    }

    private func attachScheduling() {
        observers.append(center.addObserver(forName: .credentialsChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? SyncChangeToken
            Task { @MainActor [weak self] in
                guard let self, source !== self.ownChange else { return }
                self.scheduleLocalChange()
            }
        })
        observers.append(center.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.accountChanged() }
        })
        let delay = max(interval, 1_000_000)
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: delay) } catch { return }
                guard let self, self.started else { return }
                if self.state.enabled, self.state.phase == .ready { self.perform(.syncNow) }
            }
        }
        if systemSignals { attachSystemSignals() }
    }

    private func attachSystemSignals() {
        systemObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.systemResumed() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor [weak self] in self?.networkChanged(satisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "KeyKeeper.iCloudSync.network"))
        pathMonitor = monitor
    }

    private func networkChanged(satisfied: Bool) {
        defer { networkSatisfied = satisfied }
        if satisfied, networkSatisfied == false { systemResumed() }
    }

    /// Wake from sleep or the network coming back: the moment a paused sync is most likely to work,
    /// and the moment a running one has most likely missed the other Mac's changes.
    func systemResumed() {
        guard started, !stopRequested else { return }
        if state.retriesAutomatically {
            retryAttempt = 0
            cancelAutoRetry()
            retryNow()
        } else if state.enabled, state.phase == .ready, activeTask == nil {
            perform(.syncNow)
        }
    }

    /// Schedules the next automatic retry while a pause it can clear lasts; anything else cancels it.
    private func updateAutoRetry() {
        guard started, !stopRequested, state.retriesAutomatically, !retryDelays.isEmpty else {
            cancelAutoRetry()
            if state.phase == .ready || state.phase == .off { retryAttempt = 0 }
            return
        }
        guard activeTask == nil else { return }
        if retryTask != nil { state.nextRetry = retryDue; return }
        let delay = max(retryDelays[min(retryAttempt, retryDelays.count - 1)], 1_000_000)
        retryAttempt += 1
        let due = Date().addingTimeInterval(TimeInterval(delay) / 1_000_000_000)
        retryDue = due
        state.nextRetry = due
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil; self.retryDue = nil
            self.retryNow()
        }
    }

    private func retryNow() {
        guard started, !stopRequested, state.retriesAutomatically, activeTask == nil else { return }
        perform(.retry)
    }

    private func cancelAutoRetry() {
        retryTask?.cancel(); retryTask = nil; retryDue = nil
        state.nextRetry = nil
    }

    private func scheduleLocalChange() {
        guard started, state.enabled, state.phase == .ready || state.phase == .conflict || activeTask != nil else { return }
        localChangePending = true
        delayedChange?.cancel()
        let delay = max(debounce, 1_000_000)
        delayedChange = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.started, self.state.enabled, self.activeTask == nil else { return }
            self.localChangePending = false
            self.perform(.syncNow)
        }
    }

    private func accountChanged() async {
        guard started, state.enabled, let engine else { return }
        actionEpoch &+= 1
        delayedChange?.cancel(); delayedChange = nil; localChangePending = false
        retryAttempt = 0
        await engine.accountChanged()
        await refresh()
    }

    static func presentation(_ status: CloudSyncStatus) -> ICloudSyncPresentation {
        let phase: ICloudSyncPresentation.Phase
        switch status.phase {
        case .off: phase = .off
        case .ready, .synced: phase = .ready
        case .syncing: phase = .syncing
        case .conflicts: phase = .conflict
        case .paused: phase = .paused
        }
        let issue: ICloudSyncPresentation.Issue?
        switch status.error {
        case .accountChanged: issue = .accountChanged
        case .pendingUpload: issue = .pendingUpload
        case .stateUnavailable: issue = .storageUnavailable
        case .localDataUnavailable: issue = .incompleteVault
        case .unsupportedSnapshotVersion: issue = .unsupportedSnapshotVersion
        case .localChanged: issue = .stale
        case .setupRequired: issue = .incompleteVault
        case .unavailable, .busy: issue = .networkUnavailable
        case .conflict, nil: issue = nil
        }
        let review = status.reviewID.map { id in
            ICloudSyncPresentation.ConflictReview(id: id, rows: status.conflicts.map {
                .init(id: $0.credentialID, label: $0.title,
                      localExists: !$0.localDeleted, remoteExists: !$0.remoteDeleted,
                      canChooseLocal: $0.canChooseLocal, canChooseRemote: $0.canChooseRemote)
            })
        }
        return .init(phase: phase, enabled: status.enabled, lastSuccess: status.lastSuccess, issue: issue, review: review,
                     missingCredentialCount: status.missingCredentialCount, missingFieldCount: status.missingFieldCount)
    }
}

final class SyncChangeToken: NSObject, @unchecked Sendable {}

private final class NotifyingSyncLocalStore: CloudSyncLocalStore, @unchecked Sendable {
    let store: any CloudSyncLocalStore
    let center: NotificationCenter
    let token: SyncChangeToken
    init(store: any CloudSyncLocalStore, center: NotificationCenter, token: SyncChangeToken) {
        self.store = store; self.center = center; self.token = token
    }
    func capture() throws -> CloudSyncLocalCapture { try store.capture() }
    func apply(_ desired: CloudVaultSnapshot, expectedRevision: VaultRevision) throws -> [String] {
        let changed = try store.apply(desired, expectedRevision: expectedRevision)
        if !changed.isEmpty {
            DispatchQueue.main.async { [center, token] in center.post(name: .credentialsChanged, object: token) }
        }
        return changed
    }
}
