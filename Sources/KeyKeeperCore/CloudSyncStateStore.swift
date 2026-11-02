import Foundation

/// The local half of a cycle is recorded before applying it. All snapshots are secret-bearing.
public struct CloudSyncLocalTransition: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let beforeData: Data
    public let desiredData: Data
    public let remoteData: Data?
    public let upload: CloudSyncPendingUpload?
    public init(beforeData: Data, desiredData: Data, remoteData: Data?, upload: CloudSyncPendingUpload?) {
        self.beforeData = beforeData; self.desiredData = desiredData
        self.remoteData = remoteData; self.upload = upload
    }
    public var description: String { "CloudSyncLocalTransition(<redacted>)" }
    public var debugDescription: String { description }
    func validate() throws {
        _ = try CloudVaultSnapshot.decode(beforeData)
        _ = try CloudVaultSnapshot.decode(desiredData)
        if let remoteData { _ = try CloudVaultSnapshot.decode(remoteData) }
        try upload?.validate()
        if let upload {
            guard (remoteData == nil) == (upload.expectedRevisionID == nil) else { throw CloudSyncError.stateUnavailable }
        }
        guard upload?.snapshotData == desiredData || upload == nil && desiredData == remoteData else {
            throw CloudSyncError.stateUnavailable
        }
    }
}

public struct CloudSyncStoredState: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var enabled: Bool
    public var binding: CloudSyncBinding?
    public var baseData: Data?
    public var pending: CloudSyncPendingUpload?
    public var transition: CloudSyncLocalTransition?
    public var lastSuccess: Date?
    public var accountChangePaused: Bool
    public init(enabled: Bool = false, binding: CloudSyncBinding? = nil, baseData: Data? = nil,
                pending: CloudSyncPendingUpload? = nil, transition: CloudSyncLocalTransition? = nil,
                lastSuccess: Date? = nil, accountChangePaused: Bool = false) {
        self.enabled = enabled; self.binding = binding; self.baseData = baseData
        self.pending = pending; self.transition = transition; self.lastSuccess = lastSuccess
        self.accountChangePaused = accountChangePaused
    }
    public func validate() throws {
        guard binding != nil || !enabled && baseData == nil && pending == nil && transition == nil && lastSuccess == nil else {
            throw CloudSyncError.stateUnavailable
        }
        try binding?.validate()
        if let baseData { _ = try CloudVaultSnapshot.decode(baseData) }
        try pending?.validate(); try transition?.validate()
        if let pending {
            guard (baseData == nil) == (pending.expectedRevisionID == nil) else { throw CloudSyncError.stateUnavailable }
        }
        if let lastSuccess, !lastSuccess.timeIntervalSince1970.isFinite { throw CloudSyncError.stateUnavailable }
    }
    public var description: String { "CloudSyncStoredState(<redacted>)" }
    public var debugDescription: String { description }
}

public protocol CloudSyncStateStoring: AnyObject, Sendable {
    func load() throws -> CloudSyncStoredState?
    func save(_ state: CloudSyncStoredState) throws
}

/// Never synchronizable: grants and sync bookkeeping remain independently owned by this Mac.
public final class CloudSyncStateStore: CloudSyncStateStoring, @unchecked Sendable {
    private struct Document: Codable { let version: Int; let namespace: String; let state: CloudSyncStoredState }
    private let io: KeychainBlobIO
    private let marker: any LocalVaultJournalMarker
    private let namespace: String
    private let lock = NSRecursiveLock()
    // Base + old pending + transition can contain six bounded snapshots and two opaque tokens.
    public static let maximumBytes = 8 * 1024 * 1024
    public init(io: KeychainBlobIO, marker: any LocalVaultJournalMarker, namespace: String) {
        self.io = io; self.marker = marker; self.namespace = namespace
    }
    public func load() throws -> CloudSyncStoredState? {
        try lock.withLock {
            do {
                let created = try marker.wasCreated()
                guard let data = try io.readBlobWithoutInteraction() else {
                    guard !created else { throw CloudSyncError.stateUnavailable }
                    return nil
                }
                guard created else { throw CloudSyncError.stateUnavailable }
                return try decode(data)
            } catch { throw CloudSyncError.stateUnavailable }
        }
    }
    public func save(_ state: CloudSyncStoredState) throws {
        try lock.withLock {
            do {
                guard !namespace.isEmpty, namespace.utf8.count <= 1024 else { throw CloudSyncError.stateUnavailable }
                try state.validate()
                let previous = try load()
                let bytes = try CloudVaultSnapshot.encode(Document(version: 1, namespace: namespace, state: state))
                guard bytes.count <= Self.maximumBytes else { throw CloudSyncError.stateUnavailable }
                do { try io.writeBlob(bytes, replacingExisting: previous != nil) }
                catch { /* Exact readback alone resolves an uncertain write; never repeat it. */ }
                guard try io.readBlobWithoutInteraction() == bytes else { throw CloudSyncError.stateUnavailable }
                if previous == nil {
                    do { try marker.markCreated() } catch { }
                    guard try marker.wasCreated() else { throw CloudSyncError.stateUnavailable }
                }
                guard try load() == state else { throw CloudSyncError.stateUnavailable }
            } catch { throw CloudSyncError.stateUnavailable }
        }
    }
    private func decode(_ data: Data) throws -> CloudSyncStoredState {
        guard data.count <= Self.maximumBytes, !namespace.isEmpty, namespace.utf8.count <= 1024 else {
            throw CloudSyncError.stateUnavailable
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.namespace == namespace,
              try CloudVaultSnapshot.encode(document) == data else { throw CloudSyncError.stateUnavailable }
        try document.state.validate()
        return document.state
    }
}
