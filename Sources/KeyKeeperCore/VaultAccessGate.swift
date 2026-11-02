import Foundation

public enum VaultAccessError: Error, Equatable, LocalizedError {
    case recoveryRequired
    case staleEpoch

    public var errorDescription: String? {
        switch self {
        case .recoveryRequired: "The credential store needs recovery before it can be used."
        case .staleEpoch: "The credential store changed while this request was waiting. Request access again."
        }
    }
}

/// The outermost lock for the local vault. Store-specific locks must only be acquired inside it.
/// Transaction adapters use private raw IO; public access remains closed until commit completes.
public final class VaultAccessGate: @unchecked Sendable {
    public static let production = VaultAccessGate {
        try LocalVaultJournal.production().requireReady()
    }

    private enum State { case unchecked, ready, blocked }
    private let lock = NSRecursiveLock()
    private let admission: () throws -> Void
    private let instanceID = UUID()
    private var state = State.unchecked
    private var epoch: UInt64 = 0
    private var accessDepth = 0

    public init(admission: @escaping () throws -> Void = {}) {
        self.admission = admission
    }

    public func withAccess<T>(expectedEpoch: UInt64? = nil, _ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try requireReady()
        if let expectedEpoch, expectedEpoch != epoch { throw VaultAccessError.staleEpoch }
        accessDepth += 1
        defer { accessDepth -= 1 }
        return try body()
    }

    public func captureEpoch() throws -> UInt64 { try withAccess { epoch } }

    /// The caller must load verified metadata and capture this token in one outer lease.
    public func revision(for metadata: MetaFile) throws -> VaultRevision {
        try withAccess {
            VaultRevision(instanceID: instanceID, epoch: epoch,
                metadataDigest: try VaultRevision.metadataDigest(for: metadata))
        }
    }

    /// `metadata` must be the current verified image loaded inside the caller's outer lease.
    public func validateRevision(_ revision: VaultRevision?, metadata: MetaFile, required: Bool) throws {
        try withAccess {
            guard let revision else {
                if required { throw VaultRevisionError.required }
                return
            }
            try revision.validate()
            guard revision == (try self.revision(for: metadata)) else { throw VaultRevisionError.stale }
        }
    }

    /// Called immediately before protected-value IO, while its outer access lease is held.
    /// Even an uncertain failed write makes earlier readers stale. Ordinary CRUD errors do
    /// not acquire transaction recovery semantics or perform another native admission read.
    func noteValueMutation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard state == .ready, accessDepth > 0 else { throw VaultAccessError.recoveryRequired }
        guard epoch < UInt64.max else {
            state = .blocked
            throw VaultAccessError.recoveryRequired
        }
        epoch += 1
    }

    /// May be entered recursively from a normal access lease without releasing the outer lock.
    func withCommit<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try requireReady()
        return try advance(body)
    }

    /// Recovery is the only operation that can reopen a blocked vault.
    func withRecovery<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try advance(body)
    }

    private func advance<T>(_ body: () throws -> T) throws -> T {
        state = .blocked
        guard epoch < UInt64.max else { throw VaultAccessError.recoveryRequired }
        epoch += 1
        let result = try body()
        state = .ready
        return result
    }

    private func requireReady() throws {
        guard state != .blocked else { throw VaultAccessError.recoveryRequired }
        // Every outer operation rechecks the durable journal. Nested store calls share the
        // already-validated lease, so a multi-field operation does not repeat native IO.
        if accessDepth == 0 {
            state = .blocked
            try admission()
            state = .ready
        }
        guard state == .ready else { throw VaultAccessError.recoveryRequired }
    }
}
