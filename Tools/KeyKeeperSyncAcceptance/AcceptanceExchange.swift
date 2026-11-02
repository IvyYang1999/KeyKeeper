#if KEYKEEPER_SYNC_ACCEPTANCE
import Foundation
import KeyKeeperCore

enum AcceptanceExchange {
    static func run(_ options: AcceptanceOptions) async throws {
        let empty = try AcceptanceFixture.empty()
        let seed = try AcceptanceFixture.snapshot(runID: options.runID, advanced: false)
        let advanced = try AcceptanceFixture.snapshot(runID: options.runID, advanced: true)
        if options.command != "inspect" {
            let expected = options.command == "seed" ? empty : options.command == "advance" ? seed : advanced
            guard try AcceptanceFixture.digest(expected) == options.expectedDigest else { throw AcceptanceFailure.digest }
        }
        // Signature/entitlement validation happens before even the isolated local stores open.
        let identity = try CloudSyncNativeIdentity.current()
        let fresh = options.command == "seed" || options.command == "advance"
        let directory = try AcceptanceDirectory(options: options, create: fresh)
        defer { withExtendedLifetime(directory) {} }
        let stores = try CloudSyncAcceptanceStores.open(runID: options.runID, clientID: options.clientID,
                                                       initializeIfAbsent: fresh)
        if options.command == "inspect" {
            let snapshot = try stores.local.capture().snapshot
            guard try AcceptanceFixture.matches(snapshot, empty)
                    || AcceptanceFixture.matches(snapshot, seed) || AcceptanceFixture.matches(snapshot, advanced),
                  try AcceptanceFixture.digest(snapshot) == options.expectedDigest else { throw AcceptanceFailure.digest }
            let state = try stores.stateStore.load()
            print("PASS inspect snapshot_sha256=\(try AcceptanceFixture.digest(snapshot)) enabled=\(state?.enabled == true) pending=\(state?.pending != nil) transition=\(state?.transition != nil)")
            return
        }
        _ = try stores.local.recover()
        let factory = AcceptanceTransportFactory(identity: identity, runID: options.runID)
        let coordinator = CloudSyncCoordinator(local: stores.local, stateStore: stores.stateStore,
                                               makeTransport: { try factory.make() })
        await coordinator.load()
        let initialStatus = await coordinator.status
        guard initialStatus.phase == .off, !initialStatus.enabled, factory.count == 0 else { throw AcceptanceFailure.state }
        if fresh {
            guard try stores.stateStore.load() == nil,
                  try AcceptanceFixture.matches(stores.local.capture().snapshot, empty),
                  try stores.approvals.all().isEmpty else { throw AcceptanceFailure.state }
        }
        // The command itself explicitly opts this test in. Check its expected remote
        // starting point before enable can bootstrap an absent head from an empty Mac B.
        let preflight = try factory.make()
        let binding = try await preflight.binding()
        let remote = try await preflight.fetch(binding: binding)
        if options.command == "seed" {
            guard remote == nil else { throw AcceptanceFailure.state }
        } else {
            let expected = options.command == "advance" ? seed : advanced
            guard let remote, try AcceptanceFixture.matches(remote.snapshot, expected) else { throw AcceptanceFailure.digest }
        }
        switch options.command {
        case "seed":
            let capture = try stores.local.capture()
            _ = try stores.local.apply(seed, expectedRevision: capture.revision)
            try stores.approvals.add(.init(id: grantID(options),
                subject: .init(fingerprint: "acceptance:" + options.clientID.uuidString, displayName: "Synthetic client A"),
                target: .credential(id: AcceptanceFixture.credentialID(options.runID), fields: nil), duration: .always))
            try requireGrant(stores, options: options, present: true)
            await coordinator.enable()
            try await requireSynced(coordinator, stores: stores, snapshot: seed)
            // Exercise server-populated CKRecord system fields through the production archive/restore path.
            try await exerciseCAS(factory.transport, snapshot: seed, rejected: advanced)
            await coordinator.syncNow()
            try await requireSynced(coordinator, stores: stores, snapshot: seed)
            try requireGrant(stores, options: options, present: true)
            try await finishOff(coordinator, options: options, snapshot: seed, identity: identity)
            print("PASS seed snapshot_sha256=\(try AcceptanceFixture.digest(seed)) credentials=1 local_grants=1 stale_cas=rejected")
        case "advance":
            await coordinator.enable()
            try await requireSynced(coordinator, stores: stores, snapshot: seed)
            guard try stores.approvals.all().isEmpty else { throw AcceptanceFailure.grants }
            let capture = try stores.local.capture()
            guard try AcceptanceFixture.digest(capture.snapshot) == options.expectedDigest else { throw AcceptanceFailure.digest }
            _ = try stores.local.apply(advanced, expectedRevision: capture.revision)
            await coordinator.syncNow()
            try await requireSynced(coordinator, stores: stores, snapshot: advanced)
            guard try stores.approvals.all().isEmpty else { throw AcceptanceFailure.grants }
            try await finishOff(coordinator, options: options, snapshot: advanced, identity: identity)
            print("PASS advance snapshot_sha256=\(try AcceptanceFixture.digest(advanced)) credentials=1 local_grants_transferred=0")
        case "verify":
            guard try AcceptanceFixture.matches(stores.local.capture().snapshot, seed) else { throw AcceptanceFailure.state }
            try requireGrant(stores, options: options, present: true)
            await coordinator.enable()
            try await requireSynced(coordinator, stores: stores, snapshot: advanced)
            try requireGrant(stores, options: options, present: false)
            try await finishOff(coordinator, options: options, snapshot: advanced, identity: identity)
            print("PASS verify snapshot_sha256=\(try AcceptanceFixture.digest(advanced)) credentials=1 local_grants_revoked=1")
        default: throw AcceptanceFailure.arguments
        }
    }

    private static func requireSynced(_ coordinator: CloudSyncCoordinator, stores: CloudSyncAcceptanceStores,
                                      snapshot: CloudVaultSnapshot) async throws {
        let status = await coordinator.status
        if let error = status.error { throw error }
        guard status.enabled, status.phase == .synced, !status.busy,
              let state = try stores.stateStore.load(), state.enabled, state.pending == nil, state.transition == nil,
              state.baseData == (try snapshot.encoded()),
              try AcceptanceFixture.matches(stores.local.capture().snapshot, snapshot)
        else { throw AcceptanceFailure.sync }
    }

    private static func finishOff(_ coordinator: CloudSyncCoordinator, options: AcceptanceOptions,
                                  snapshot: CloudVaultSnapshot, identity: CloudSyncNativeIdentity) async throws {
        await coordinator.disable()
        let stores = try CloudSyncAcceptanceStores.open(runID: options.runID, clientID: options.clientID,
                                                       initializeIfAbsent: false)
        let factory = AcceptanceTransportFactory(identity: identity, runID: options.runID)
        let restored = CloudSyncCoordinator(local: stores.local, stateStore: stores.stateStore,
                                            makeTransport: { try factory.make() })
        await restored.load()
        let status = await restored.status
        guard status.phase == .off, !status.enabled, factory.count == 0,
              try stores.stateStore.load()?.enabled == false,
              try AcceptanceFixture.matches(stores.local.capture().snapshot, snapshot)
        else { throw AcceptanceFailure.state }
    }

    private static func exerciseCAS(_ transport: CloudKitSyncTransport?, snapshot: CloudVaultSnapshot,
                                    rejected: CloudVaultSnapshot) async throws {
        guard let transport else { throw AcceptanceFailure.state }
        let binding = try await transport.binding()
        guard let before = try await transport.fetch(binding: binding),
              try AcceptanceFixture.matches(before.snapshot, snapshot) else { throw AcceptanceFailure.state }
        let winner = CloudSyncPendingUpload(id: UUID(), snapshotData: try snapshot.encoded(),
            expectedRevisionID: before.revisionID, expectedChangeToken: before.changeToken)
        try await transport.upload(winner, binding: binding)
        guard let after = try await transport.fetch(binding: binding), after.revisionID == winner.id,
              after.revisionID != before.revisionID, try AcceptanceFixture.matches(after.snapshot, snapshot)
        else { throw AcceptanceFailure.cas }
        let stale = CloudSyncPendingUpload(id: UUID(), snapshotData: try rejected.encoded(),
            expectedRevisionID: before.revisionID, expectedChangeToken: before.changeToken)
        do { try await transport.upload(stale, binding: binding); throw AcceptanceFailure.cas }
        catch CloudSyncError.conflict { }
        guard let retained = try await transport.fetch(binding: binding), retained.revisionID == after.revisionID,
              try AcceptanceFixture.matches(retained.snapshot, snapshot) else { throw AcceptanceFailure.cas }
    }

    private static func grantID(_ options: AcceptanceOptions) -> String { "acceptance-local-" + options.clientID.uuidString }
    private static func requireGrant(_ stores: CloudSyncAcceptanceStores, options: AcceptanceOptions, present: Bool) throws {
        let grants = try stores.approvals.all()
        guard present ? grants.count == 1 && grants[0].id == grantID(options) : grants.isEmpty else { throw AcceptanceFailure.grants }
    }
}

private final class AcceptanceTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let identity: CloudSyncNativeIdentity
    private let runID: UUID
    private var constructions = 0
    private var latest: CloudKitSyncTransport?
    init(identity: CloudSyncNativeIdentity, runID: UUID) { self.identity = identity; self.runID = runID }
    var count: Int { lock.withLock { constructions } }
    var transport: CloudKitSyncTransport? { lock.withLock { latest } }
    func make() throws -> CloudKitSyncTransport {
        lock.withLock {
            let native = CloudKitSyncTransport(identity: identity, acceptanceRunID: runID)
            latest = native; constructions += 1
            return native
        }
    }
}
#endif
